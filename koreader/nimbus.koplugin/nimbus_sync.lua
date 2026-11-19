--[[--
nimbus_sync.lua
Core sync orchestrator for nimbus.koplugin:
- Offline pending queue
- Remote catalog & device shard read/write
- Whispersync progress & annotation merge on book open/close
- Book upload + cover extraction + catalog update
--]]

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end
local ok_util, util = pcall(require, "util")

local Constants = require("nimbus_constants")
local Settings = require("nimbus_settings")
local Http = require("nimbus_http")
local Cloud = require("nimbus_cloud")
local Hash = require("nimbus_hash")
local Matcher = require("nimbus_matcher")
local Merge = require("nimbus_merge")
local Stats = require("nimbus_stats")

local Sync = {}

local function getQueuePath()
    return Settings.getNimbusDir() .. "/queue.lua"
end

local function getLocalStatePath()
    return Settings.getNimbusDir() .. "/local_state.lua"
end

function Sync.loadQueue()
    return Settings.readLuaTable(getQueuePath()) or {}
end

function Sync.saveQueue(q)
    return Settings.writeLuaTable(getQueuePath(), q or {})
end

function Sync.enqueue(op)
    local q = Sync.loadQueue()
    table.insert(q, op)
    Sync.saveQueue(q)
end

function Sync.loadLocalState()
    local st = Settings.readLuaTable(getLocalStatePath()) or {}
    st.progress = st.progress or {}
    st.annotations = st.annotations or {}
    return st
end

function Sync.saveLocalState(st)
    return Settings.writeLuaTable(getLocalStatePath(), st)
end

local function getCatalogCachePath()
    return Settings.getNimbusDir() .. "/catalog_cache.lua"
end

function Sync.loadCachedCatalog()
    local cached = Settings.readLuaTable(getCatalogCachePath())
    if type(cached) == "table" and type(cached.catalog) == "table" then
        return cached.catalog, cached.merged_progress or {}, cached.saved_at
    end
    return { books = {} }, {}, 0
end

function Sync.saveCachedCatalog(catalog, merged_progress)
    if type(catalog) ~= "table" then return false end
    return Settings.writeLuaTable(getCatalogCachePath(), {
        saved_at = os.time(),
        catalog = catalog,
        merged_progress = merged_progress or {},
    })
end

function Sync.loadCatalog(cb)
    Cloud.downloadString("_sync/catalog.json", function(ok, body_or_err)
        if not ok then
            if body_or_err == "not_found" then
                local empty_cat = {
                    version = Constants.SCHEMA_VERSION,
                    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
                    updated_by = Settings.load().device_id,
                    books = {},
                }
                Sync.saveCachedCatalog(empty_cat, nil)
                return cb(true, empty_cat)
            end
            return cb(false, body_or_err)
        end
        local data = Http.jsonDecode(body_or_err)
        if not data or type(data.books) ~= "table" then
            return cb(false, "Invalid catalog.json format")
        end
        local _, prev_prog = Sync.loadCachedCatalog()
        Sync.saveCachedCatalog(data, prev_prog)
        cb(true, data)
    end)
end

function Sync.saveCatalog(catalog, cb)
    catalog.version = Constants.SCHEMA_VERSION
    catalog.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    catalog.updated_by = Settings.load().device_id
    Cloud.uploadString("_sync/catalog.json", Http.jsonEncode(catalog), "application/json", cb)
end

function Sync.listDevices(cb)
    Cloud.listDir("_sync/devices", function(ok, entries)
        if not ok then return cb(false, entries) end
        local devices = {}
        for _, e in ipairs(entries or {}) do
            if e.is_dir and e.name and e.name ~= "" then
                table.insert(devices, e.name)
            end
        end
        cb(true, devices)
    end)
end

function Sync.fetchAllDeviceShards(shard_filename, cb)
    Sync.listDevices(function(ok, devices)
        if not ok then return cb(false, devices) end
        local shards = {}
        for _, dev_id in ipairs(devices) do
            Cloud.downloadString("_sync/devices/" .. dev_id .. "/" .. shard_filename, function(ok_dl, body)
                if ok_dl and body then
                    local decoded = Http.jsonDecode(body)
                    if type(decoded) == "table" then
                        decoded.device_id = decoded.device_id or dev_id
                        table.insert(shards, decoded)
                    end
                end
            end)
        end
        cb(true, shards)
    end)
end

function Sync.uploadDeviceProgress(progress_books, cb)
    local cfg = Settings.load()
    local payload = {
        version = Constants.SCHEMA_VERSION,
        device_id = cfg.device_id,
        updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        books = progress_books or {},
    }
    local rel = "_sync/devices/" .. cfg.device_id .. "/progress.json"
    Cloud.uploadString(rel, Http.jsonEncode(payload), "application/json", function(ok, err)
        if not ok then
            Sync.enqueue({ type = "upload_json", rel_path = rel, body = Http.jsonEncode(payload) })
        end
        if cb then cb(ok, err) end
    end)
end

function Sync.uploadDeviceAnnotations(annotations_books, cb)
    local cfg = Settings.load()
    local payload = {
        version = Constants.SCHEMA_VERSION,
        device_id = cfg.device_id,
        updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        books = annotations_books or {},
    }
    local rel = "_sync/devices/" .. cfg.device_id .. "/annotations.json"
    Cloud.uploadString(rel, Http.jsonEncode(payload), "application/json", function(ok, err)
        if not ok then
            Sync.enqueue({ type = "upload_json", rel_path = rel, body = Http.jsonEncode(payload) })
        end
        if cb then cb(ok, err) end
    end)
end

function Sync.flushQueue(cb)
    if not Cloud.isConfigured() then
        if cb then cb(true, 0) end
        return
    end
    local q = Sync.loadQueue()
    if #q == 0 then
        if cb then cb(true, 0) end
        return
    end
    local remaining = {}
    local flushed = 0
    for _, op in ipairs(q) do
        if op.type == "upload_json" and op.rel_path and op.body then
            local ok_up = false
            Cloud.uploadString(op.rel_path, op.body, "application/json", function(ok)
                ok_up = ok
            end)
            if ok_up then
                flushed = flushed + 1
            else
                table.insert(remaining, op)
            end
        end
    end
    Sync.saveQueue(remaining)
    if cb then cb(#remaining == 0, flushed) end
end

local function sanitizeFolderPart(str, fallback)
    local s = tostring(str or fallback or "Unknown"):gsub('[\\/:*?"<>|]', "_"):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then s = fallback or "Unknown" end
    return s:sub(1, 60)
end

--- Uploads a local book to Books/<Author> - <Title> [<id>]/ and updates catalog.json.
function Sync.uploadBook(filepath, doc_props, cover_path, cb, opts)
    if not Cloud.isConfigured() then
        return cb(false, "Cloud provider is not configured")
    end
    opts = opts or {}
    doc_props = doc_props or {}
    local title = doc_props.title or (filepath:match("([^/\\]+)%.[^%.]+$")) or "Untitled"
    local authors = doc_props.authors
    if type(authors) == "string" then
        authors = { authors }
    elseif type(authors) ~= "table" or #authors == 0 then
        authors = { "Unknown Author" }
    end

    local ext = (filepath:match("%.([^%.]+)$") or "epub"):lower()
    local filename = filepath:match("([^/\\]+)$") or ("book." .. ext)
    local partial_md5 = doc_props.partial_md5 or Hash.partialMD5(filepath)
    local sha256 = doc_props.sha256 or Hash.sha256File(filepath)
    local attr = lfs and lfs.attributes(filepath)
    local size_bytes = (attr and attr.size) or 0

    Sync.loadCatalog(function(ok_cat, catalog_or_err)
        if not ok_cat then return cb(false, catalog_or_err) end
        local catalog = catalog_or_err

        -- Check if already in catalog
        local existing_id = Matcher.resolve(filepath, catalog, {
            partial_md5 = partial_md5,
            sha256 = sha256,
            title = title,
            authors = authors[1],
            isbn = doc_props.isbn,
        })
        local book_id = existing_id or Hash.generateBookId()
        local folder = string.format("Books/%s - %s [%s]",
            sanitizeFolderPart(authors[1], "Unknown"),
            sanitizeFolderPart(title, "Untitled"),
            book_id)

        local ok_up, up_err = false, nil
        Cloud.uploadFile(folder .. "/" .. filename, filepath, function(ok, err)
            ok_up = ok
            up_err = err
        end, opts)
        if not ok_up then return cb(false, up_err) end

        local has_cover = false
        local resolved_cover = cover_path
        if not resolved_cover then
            local ok_cov, Covers = pcall(require, "nimbus_covers")
            if ok_cov and Covers and Covers.extractLocalCoverToFile then
                local cache_cov = Covers.getCoverFilePath({ id = book_id, local_path = filepath })
                if cache_cov and Covers.extractLocalCoverToFile(filepath, cache_cov, opts.open_doc) then
                    resolved_cover = cache_cov
                end
            end
        end
        if resolved_cover then
            local cf = io.open(resolved_cover, "rb")
            if cf then
                cf:close()
                Cloud.uploadFile(folder .. "/cover.jpg", resolved_cover, function(ok_c)
                    has_cover = ok_c
                end)
            end
        end

        local rel_dir = ""
        local ok_sc, Scanner = pcall(require, "nimbus_scanner")
        if ok_sc and Scanner and Scanner.getRelativeDir then
            rel_dir = Scanner.getRelativeDir(filepath)
        end

        local now_iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
        local entry = {
            id = book_id,
            title = title,
            authors = authors,
            series = doc_props.series,
            series_index = doc_props.series_index,
            tags = doc_props.tags or {},
            language = doc_props.language,
            isbn = doc_props.isbn,
            calibre_uuid = nil,
            folder = folder,
            relative_dir = rel_dir,
            filename = filename,
            format = Constants.SUPPORTED_FORMATS[ext] and ext or "epub",
            size_bytes = size_bytes,
            has_cover = has_cover,
            cover_etag = has_cover and tostring(os.time()) or nil,
            hashes = {
                partial_md5 = partial_md5 or "",
                sha256 = sha256 or "",
            },
            added_at = (catalog.books[book_id] and catalog.books[book_id].added_at) or now_iso,
            updated_at = now_iso,
            deleted = false,
        }

        Cloud.uploadString(folder .. "/metadata.json", Http.jsonEncode(entry), "application/json", function() end)
        catalog.books[book_id] = entry
        Sync.saveCatalog(catalog, function(ok_save, save_err)
            if not ok_save then return cb(false, save_err) end
            Settings.linkBook(filepath, book_id)
            cb(true, entry)
        end)
    end)
end

--- Backfills `relative_dir` onto existing catalog entries matched to local books.
function Sync.backfillRelativeDirs(catalog, device_books)
    if type(catalog) ~= "table" or type(catalog.books) ~= "table" then return false end
    local ok_sc, Scanner = pcall(require, "nimbus_scanner")
    if not ok_sc or not Scanner or not Scanner.getRelativeDir then return false end
    local changed = false
    for _, b in ipairs(device_books or {}) do
        if b.cloud_id and b.local_path and catalog.books[b.cloud_id] then
            local entry = catalog.books[b.cloud_id]
            if not entry.relative_dir or entry.relative_dir == "" then
                local rel = Scanner.getRelativeDir(b.local_path)
                if rel and rel ~= "" then
                    entry.relative_dir = rel
                    changed = true
                end
            end
        end
    end
    return changed
end

--- Syncs reading statistics for the active month (and optionally imports remote sessions).
function Sync.syncStats(cb)
    if not Cloud.isConfigured() then
        if cb then cb(false, "Not configured") end
        return
    end
    local cfg = Settings.load()
    if not cfg.sync_stats then
        if cb then cb(true, 0) end
        return
    end
    Sync.loadCatalog(function(ok_cat, catalog)
        if not ok_cat then
            if cb then cb(false, catalog) end
            return
        end
        local md5_to_id = {}
        for id, entry in pairs(catalog.books or {}) do
            if not entry.deleted and entry.hashes and entry.hashes.partial_md5 then
                md5_to_id[entry.hashes.partial_md5] = id
            end
        end
        local month = os.date("!%Y-%m")
        local exported = Stats.exportMonthlySessions(md5_to_id, month)
        local sessions = exported[month] or {}
        local payload = {
            version = Constants.SCHEMA_VERSION,
            device_id = cfg.device_id,
            month = month,
            sessions = sessions,
        }
        local rel = "_sync/devices/" .. cfg.device_id .. "/sessions/" .. month .. ".json"
        Cloud.uploadString(rel, Http.jsonEncode(payload), "application/json", function(ok_up, err)
            if cb then cb(ok_up, ok_up and #sessions or err) end
        end)
    end)
end

return Sync
