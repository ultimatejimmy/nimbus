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
local Logger = require("nimbus_logger")
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

function Sync.clearCachedCatalog()
    Sync._last_bg_sync_ts = nil
    pcall(os.remove, getCatalogCachePath())
end

local function getPrimaryAuthor(entry)
    if type(entry.authors) == "table" and entry.authors[1] then
        return Matcher.normalizeText(entry.authors[1])
    elseif type(entry.authors) == "string" then
        return Matcher.normalizeText(entry.authors)
    end
    return ""
end

--- Deduplicates catalog.books in-place by sha256, partial_md5, isbn, or normalized (title, author).
-- Keeps the best canonical entry, marks duplicates deleted=true, and remaps local book_links.
-- @return number removed_count, table dup_folders
function Sync.deduplicateCatalog(catalog)
    if type(catalog) ~= "table" or type(catalog.books) ~= "table" then
        return 0, {}
    end
    local entries = {}
    for id, entry in pairs(catalog.books) do
        if type(entry) == "table" and not entry.deleted then
            entry.id = entry.id or id
            table.insert(entries, entry)
        end
    end
    table.sort(entries, function(a, b)
        local ac = a.has_cover and 1 or 0
        local bc = b.has_cover and 1 or 0
        if ac ~= bc then return ac > bc end
        local as = (a.hashes and a.hashes.sha256 and a.hashes.sha256 ~= "") and 1 or 0
        local bs = (b.hashes and b.hashes.sha256 and b.hashes.sha256 ~= "") and 1 or 0
        if as ~= bs then return as > bs end
        local aa = tostring(a.added_at or "9999")
        local ba = tostring(b.added_at or "9999")
        if aa ~= ba then return aa < ba end
        return tostring(a.id) < tostring(b.id)
    end)

    local by_sha, by_pmd5, by_isbn, by_ta, by_file, by_tsize, by_folder = {}, {}, {}, {}, {}, {}, {}
    local id_remap = {}
    local dup_folders = {}
    local removed = 0
    local now_iso = os.date("!%Y-%m-%dT%H:%M:%SZ")

    for _, entry in ipairs(entries) do
        local sha = entry.hashes and entry.hashes.sha256 or ""
        local pmd5 = entry.hashes and entry.hashes.partial_md5 or ""
        local isbn = entry.isbn and tostring(entry.isbn):gsub("[^%w]", "") or ""
        local norm_t = Matcher.normalizeText(entry.title)
        local norm_a = getPrimaryAuthor(entry)
        local ta_key = nil
        if norm_t ~= "" and norm_t ~= "untitled" and norm_a ~= "" and norm_a ~= "unknown author" and norm_a ~= "unknown" then
            ta_key = norm_t .. "\0" .. norm_a
        end
        local fname = entry.filename and tostring(entry.filename):lower() or ""
        local sz = tonumber(entry.size_bytes) or 0
        local file_key = (fname ~= "" and sz > 0) and (fname .. "\0" .. tostring(sz)) or nil
        local tsize_key = (norm_t ~= "" and norm_t ~= "untitled" and sz > 0) and (norm_t .. "\0" .. tostring(sz)) or nil
        local folder_key = (entry.folder and entry.folder ~= "") and tostring(entry.folder):lower() or nil

        local keep_id = (sha ~= "" and by_sha[sha])
            or (pmd5 ~= "" and by_pmd5[pmd5])
            or (isbn ~= "" and by_isbn[isbn])
            or (ta_key and by_ta[ta_key])
            or (file_key and by_file[file_key])
            or (tsize_key and by_tsize[tsize_key])
            or (folder_key and by_folder[folder_key])

        if keep_id and keep_id ~= entry.id and catalog.books[keep_id] then
            local keep = catalog.books[keep_id]
            keep.hashes = keep.hashes or {}
            if (not keep.hashes.sha256 or keep.hashes.sha256 == "") and sha ~= "" then
                keep.hashes.sha256 = sha
            end
            if (not keep.hashes.partial_md5 or keep.hashes.partial_md5 == "") and pmd5 ~= "" then
                keep.hashes.partial_md5 = pmd5
            end
            if not keep.has_cover and entry.has_cover then
                keep.has_cover = true
                keep.cover_etag = entry.cover_etag
            end
            entry.deleted = true
            entry.updated_at = now_iso
            id_remap[entry.id] = keep_id
            removed = removed + 1
            if entry.folder and entry.folder ~= "" and entry.folder ~= keep.folder then
                table.insert(dup_folders, entry.folder)
            end
        else
            if sha ~= "" then by_sha[sha] = entry.id end
            if pmd5 ~= "" then by_pmd5[pmd5] = entry.id end
            if isbn ~= "" then by_isbn[isbn] = entry.id end
            if ta_key then by_ta[ta_key] = entry.id end
            if file_key then by_file[file_key] = entry.id end
            if tsize_key then by_tsize[tsize_key] = entry.id end
            if folder_key then by_folder[folder_key] = entry.id end
        end
    end

    if removed > 0 then
        local ok_l, links = pcall(Settings.loadBookLinks)
        if ok_l and type(links) == "table" and type(links.by_path) == "table" then
            for path, lid in pairs(links.by_path) do
                if id_remap[lid] then
                    pcall(Settings.linkBook, path, id_remap[lid])
                end
            end
        end
    end

    return removed, dup_folders
end

function Sync.loadCatalog(cb, opts)
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
            Logger.warn("Failed to download catalog.json: " .. tostring(body_or_err))
            return cb(false, body_or_err)
        end
        local data = Http.jsonDecode(body_or_err)
        if not data or type(data.books) ~= "table" then
            Logger.err("Invalid catalog.json format")
            return cb(false, "Invalid catalog.json format")
        end
        local removed, dup_folders = Sync.deduplicateCatalog(data)
        if removed > 0 then
            Logger.info(string.format("Deduplicated %d duplicate cloud book(s)", removed))
            if not (opts and opts.skip_dedup_save) then
                Sync.saveCatalog(data, function() end)
                if Cloud.deletePath then
                    for _, folder in ipairs(dup_folders) do
                        pcall(Cloud.deletePath, folder, function() end)
                    end
                end
            end
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
    if flushed > 0 or #remaining > 0 then
        Logger.info(string.format("Offline queue flush: %d sent, %d remaining", flushed, #remaining))
    end
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

    local function doUploadWithCatalog(catalog)
        catalog.books = catalog.books or {}

        -- Check if already in catalog (exact hash or strong ISBN/title+author candidate)
        local existing_id, _, candidates = Matcher.resolve(filepath, catalog, {
            partial_md5 = partial_md5,
            sha256 = sha256,
            title = title,
            authors = authors[1],
            isbn = doc_props.isbn,
        }, { allow_slow_sha256 = true })
        if not existing_id and candidates and #candidates > 0 then
            existing_id = candidates[1].id
        end
        if not existing_id and filename and size_bytes > 0 then
            local fname_l = filename:lower()
            local norm_t = Matcher.normalizeText(title)
            for id, entry in pairs(catalog.books) do
                if type(entry) == "table" and not entry.deleted and tonumber(entry.size_bytes) == size_bytes then
                    local ef = entry.filename and tostring(entry.filename):lower() or ""
                    local et = Matcher.normalizeText(entry.title)
                    if (ef ~= "" and ef == fname_l) or (norm_t ~= "" and norm_t ~= "untitled" and et == norm_t) then
                        existing_id = id
                        break
                    end
                end
            end
        end
        local existing = existing_id and catalog.books[existing_id]
        if existing and not existing.deleted and not opts.force_reupload and existing.folder and existing.filename then
            Settings.linkBook(filepath, existing_id)
            Logger.info("uploadBook skipped duplicate (already in catalog): " .. tostring(title) .. " [" .. tostring(existing_id) .. "]")
            return cb(true, existing)
        end
        local book_id = existing_id or Hash.generateBookId()
        local folder = (existing and existing.folder and existing.folder ~= "") and existing.folder or string.format("Books/%s - %s [%s]",
            sanitizeFolderPart(authors[1], "Unknown"),
            sanitizeFolderPart(title, "Untitled"),
            book_id)

        local ok_up, up_err = false, nil
        Cloud.uploadFile(folder .. "/" .. filename, filepath, function(ok, err)
            ok_up = ok
            up_err = err
        end, opts)
        if not ok_up then
            Logger.warn("uploadBook failed for " .. tostring(filename) .. ": " .. tostring(up_err))
            return cb(false, up_err)
        end

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

        if not opts.skip_metadata_file then
            Cloud.uploadString(folder .. "/metadata.json", Http.jsonEncode(entry), "application/json", function() end)
        end
        catalog.books[book_id] = entry
        if opts.defer_catalog_save then
            Settings.linkBook(filepath, book_id)
            Logger.info("uploadBook complete (deferred catalog save): " .. tostring(title) .. " [" .. tostring(book_id) .. "]")
            return cb(true, entry)
        end
        Sync.saveCatalog(catalog, function(ok_save, save_err)
            if not ok_save then
                Logger.err("uploadBook failed to save catalog for " .. tostring(book_id) .. ": " .. tostring(save_err))
                return cb(false, save_err)
            end
            Settings.linkBook(filepath, book_id)
            Logger.info("uploadBook complete: " .. tostring(title) .. " [" .. tostring(book_id) .. "]")
            cb(true, entry)
        end)
    end

    if type(opts.catalog) == "table" then
        return doUploadWithCatalog(opts.catalog)
    end

    Sync.loadCatalog(function(ok_cat, catalog_or_err)
        if not ok_cat then return cb(false, catalog_or_err) end
        doUploadWithCatalog(catalog_or_err)
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

--- Marks a book deleted in the cloud catalog, removes its cloud folder, and unlinks any local copy.
function Sync.deleteCloudBook(book_id, item, cb)
    if not Cloud.isConfigured() then
        if cb then cb(false, "Not configured") end
        return
    end
    local target_id = book_id or (item and (item.cloud_id or item.id))
    if not target_id or target_id == "" then
        if cb then cb(false, "Missing book ID") end
        return
    end
    Sync.loadCatalog(function(ok_cat, cat_or_err)
        if not ok_cat or type(cat_or_err) ~= "table" then
            if cb then cb(false, cat_or_err or "Failed to load catalog") end
            return
        end
        cat_or_err.books = cat_or_err.books or {}
        local entry = cat_or_err.books[target_id]
        local folder = (entry and entry.folder) or (item and item.folder)
        if entry then
            entry.deleted = true
            entry.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
        end
        Sync.saveCatalog(cat_or_err, function(ok_save, save_err)
            if not ok_save then
                Logger.err("deleteCloudBook failed to save catalog for " .. tostring(target_id) .. ": " .. tostring(save_err))
                if cb then cb(false, save_err) end
                return
            end
            if folder and folder ~= "" then
                Cloud.deletePath(folder, function() end)
            end
            Settings.unlinkBook(target_id, item and item.local_path)
            Logger.action("Deleted cloud book: " .. tostring(target_id))
            if cb then cb(true, cat_or_err) end
        end)
    end)
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

function Sync.findNewCloudBooks(prev_cat, new_cat)
    local prev_books = (type(prev_cat) == "table" and type(prev_cat.books) == "table") and prev_cat.books or {}
    local new_books = (type(new_cat) == "table" and type(new_cat.books) == "table") and new_cat.books or {}
    local added = {}
    for id, entry in pairs(new_books) do
        if type(entry) == "table" and not entry.deleted and not prev_books[id] then
            table.insert(added, entry)
        end
    end
    return added
end

--- Non-blocking background cloud catalog + progress sync via forked subprocess (ffi/util.runInSubProcess).
function Sync.startBackgroundCatalogSync(on_complete, force)
    if not Cloud.isConfigured() or Sync._bg_pid then
        return false
    end
    local now = os.time()
    if not force and Sync._last_bg_sync_ts and (now - Sync._last_bg_sync_ts) < 30 then
        return false
    end

    local ok_fu, ffiUtil = pcall(require, "ffi/util")
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_fu or not ffiUtil or not ffiUtil.runInSubProcess or not ok_ui or not UIManager then
        return false
    end

    Sync._last_bg_sync_ts = now
    local pid, parent_read_fd = ffiUtil.runInSubProcess(function(_, child_write_fd)
        local ok_run, run_err = xpcall(function()
            local prev_cat, _, prev_saved_at = Sync.loadCachedCatalog()
            local ok_cat, cat_or_err = false, nil
            Sync.loadCatalog(function(ok, res)
                ok_cat = ok
                cat_or_err = res
            end)
            if not ok_cat then
                if child_write_fd then ffiUtil.writeToFD(child_write_fd, "ERR:" .. tostring(cat_or_err), true) end
                return
            end
            local merged = {}
            Sync.fetchAllDeviceShards("progress.json", function(ok_p, shards)
                if ok_p then
                    merged = Merge.mergeProgress(shards)
                end
            end)

            local dl_count = 0
            local cfg = Settings.load()
            if cfg.auto_download_new_books ~= false and prev_saved_at and prev_saved_at > 0 then
                local added = Sync.findNewCloudBooks(prev_cat, cat_or_err)
                if #added > 0 then
                    local ok_sc, Scanner = pcall(require, "nimbus_scanner")
                    local dirs = (ok_sc and Scanner and Scanner.getEffectiveBooksDirs) and Scanner.getEffectiveBooksDirs() or {}
                    local base_dir = (dirs[1] and dirs[1] ~= "") and dirs[1] or cfg.download_dir
                    local links = Settings.loadBookLinks()
                    for _, entry in ipairs(added) do
                        if entry.folder and entry.filename and not links.by_id[entry.id] then
                            local rel = tostring(entry.relative_dir or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
                            local target_dir = (rel ~= "") and (base_dir .. "/" .. rel) or base_dir
                            if ok_util and util and util.makePath then
                                util.makePath(target_dir)
                            end
                            local dest = target_dir .. "/" .. entry.filename
                            local existing = io.open(dest, "rb")
                            if existing then
                                existing:close()
                                Settings.linkBook(dest, entry.id)
                            else
                                local ok_dl = false
                                Cloud.downloadFile(entry.folder .. "/" .. entry.filename, dest, function(ok)
                                    ok_dl = ok
                                end)
                                if ok_dl then
                                    Settings.linkBook(dest, entry.id)
                                    dl_count = dl_count + 1
                                end
                            end
                        end
                    end
                end
            end

            Sync.saveCachedCatalog(cat_or_err, merged)
            if child_write_fd then ffiUtil.writeToFD(child_write_fd, "OK:" .. tostring(dl_count), true) end
        end, debug.traceback)
        if not ok_run and child_write_fd then
            Logger.err("Background catalog sync error: " .. tostring(run_err))
            ffiUtil.writeToFD(child_write_fd, "ERR:" .. tostring(run_err), true)
        end
    end, true)

    if not pid then
        Logger.err("Background catalog sync fork failed")
        return false
    end
    Sync._bg_pid = pid

    local attempts = 0
    local function poll()
        if Sync._bg_pid ~= pid then return end
        attempts = attempts + 1
        if attempts > 150 then
            Sync._bg_pid = nil
            Logger.warn("Background catalog sync timed out")
            if ffiUtil.terminateSubProcess then pcall(ffiUtil.terminateSubProcess, pid) end
            if ffiUtil.isSubProcessDone then pcall(ffiUtil.isSubProcessDone, pid, true) end
            if parent_read_fd and ffiUtil.readAllFromFD then pcall(ffiUtil.readAllFromFD, parent_read_fd) end
            if on_complete then on_complete(false, "timeout") end
            return
        end
        if ffiUtil.isSubProcessDone(pid) then
            Sync._bg_pid = nil
            local msg = ""
            if parent_read_fd and ffiUtil.readAllFromFD then
                local ok_r, raw = pcall(ffiUtil.readAllFromFD, parent_read_fd)
                if ok_r and type(raw) == "string" then msg = raw end
            end
            local ok_res = msg:sub(1, 3) == "OK:"
            local dl_n = ok_res and (tonumber(msg:sub(4)) or 0) or 0
            if on_complete then
                on_complete(ok_res, ok_res and dl_n or msg)
            end
            return
        end
        UIManager:scheduleIn(0.4, poll)
    end
    UIManager:scheduleIn(0.4, poll)
    return true
end

local function runConducted(opts)
    local ok, Conductor = pcall(require, "storefront_conductor")
    if ok and Conductor and Conductor.requestSlot then
        return Conductor.requestSlot(opts)
    end
    opts.run(function() end)
    return nil
end

--- Runs a blocking sync function in a background subprocess and delivers its JSON result on the UI thread.
function Sync.runInBackground(worker_fn, on_complete, opts)
    if type(worker_fn) ~= "function" then return false end
    local ok_fu, ffiUtil = pcall(require, "ffi/util")
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_fu or not ffiUtil or not ffiUtil.runInSubProcess or not ok_ui or not UIManager then
        local ok_w, res = xpcall(worker_fn, debug.traceback)
        if on_complete then on_complete(ok_w, res) end
        return true, function() end
    end

    local canceled = false
    local active_cancel = nil
    local function cancel()
        if canceled then return end
        canceled = true
        if active_cancel then active_cancel() end
    end

    runConducted({
        plugin = "nimbus",
        task = "bg_sync",
        priority = (opts and opts.priority) or "idle_bg",
        subprocess = true,
        cancel = cancel,
        run = function(done)
            local done_called = false
            local function finish_slot()
                if not done_called then
                    done_called = true
                    done()
                end
            end
            if canceled then
                finish_slot()
                return
            end

            local pid, parent_read_fd = ffiUtil.runInSubProcess(function(_pid, child_write_fd)
                local ok_run, res = xpcall(worker_fn, debug.traceback)
                if not ok_run then
                    Logger.err("Background worker exception: " .. tostring(res))
                end
                if child_write_fd then
                    local payload = Http.jsonEncode({
                        ok = ok_run,
                        res = ok_run and res or tostring(res),
                    })
                    ffiUtil.writeToFD(child_write_fd, payload, true)
                end
            end, true)

            if not pid then
                Logger.err("Sync.runInBackground fork failed")
                finish_slot()
                if on_complete then on_complete(false, "fork_failed") end
                return
            end

            active_cancel = function()
                if ffiUtil.terminateSubProcess then pcall(ffiUtil.terminateSubProcess, pid) end
                if ffiUtil.isSubProcessDone then pcall(ffiUtil.isSubProcessDone, pid, true) end
                if parent_read_fd and ffiUtil.readAllFromFD then pcall(ffiUtil.readAllFromFD, parent_read_fd) end
                finish_slot()
            end

            local attempts = 0
            local function poll()
                if canceled then
                    finish_slot()
                    return
                end
                attempts = attempts + 1
                if attempts > 180 then
                    Logger.warn("Sync.runInBackground timed out")
                    if ffiUtil.terminateSubProcess then pcall(ffiUtil.terminateSubProcess, pid) end
                    if ffiUtil.isSubProcessDone then pcall(ffiUtil.isSubProcessDone, pid, true) end
                    if parent_read_fd and ffiUtil.readAllFromFD then pcall(ffiUtil.readAllFromFD, parent_read_fd) end
                    finish_slot()
                    if on_complete then on_complete(false, "timeout") end
                    return
                end
                if ffiUtil.isSubProcessDone(pid) then
                    local msg = ""
                    if parent_read_fd and ffiUtil.readAllFromFD then
                        local ok_r, raw = pcall(ffiUtil.readAllFromFD, parent_read_fd)
                        if ok_r and type(raw) == "string" then msg = raw end
                    end
                    finish_slot()
                    local ok_dec, decoded = pcall(Http.jsonDecode, msg)
                    if ok_dec and type(decoded) == "table" then
                        if on_complete then on_complete(decoded.ok == true, decoded.res) end
                    else
                        if on_complete then on_complete(false, msg ~= "" and msg or "empty_response") end
                    end
                    return
                end
                UIManager:scheduleIn(0.3, poll)
            end
            UIManager:scheduleIn(0.3, poll)
        end,
    })

    return true, cancel
end

return Sync
