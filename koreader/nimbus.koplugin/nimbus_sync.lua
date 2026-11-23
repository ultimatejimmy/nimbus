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

local function getParsedEntryMeta(entry)
    local ok_sc, Scanner = pcall(require, "nimbus_scanner")
    if ok_sc and Scanner and Scanner.parseFilenameMetadata then
        local src = (entry.filename and entry.filename ~= "") and entry.filename or entry.title
        if src and src ~= "" then
            return Scanner.parseFilenameMetadata(src)
        end
    end
    return nil
end

local function isCleanFilename(filename)
    local stem = tostring(filename or ""):gsub("%.[^%.]+$", "")
    if stem == "" then return true end
    return stem:match("%(%d+%)$") == nil and stem:match(" %- [Cc][Oo][Pp][Yy]$") == nil
end

local function isCleanTitle(title)
    local t = tostring(title or "")
    if t == "" then return false end
    if t:match("^%d+%.?%d*%s+%-%s+") or t:match("%(%d+%)$") then return false end
    if t:match("%s+%-%s+[^%-]+$") then return false end
    return true
end

local function canonicalAuthorKey(entry)
    local raw = ""
    if type(entry.authors) == "table" and entry.authors[1] then
        raw = tostring(entry.authors[1])
    elseif type(entry.authors) == "string" then
        raw = entry.authors
    end
    local norm = Matcher.normalizeText(raw)
    if norm == "" or norm == "unknown" or norm == "unknown author" or norm == "various" then
        local parsed = getParsedEntryMeta(entry)
        if parsed and parsed.authors ~= "" then
            norm = Matcher.normalizeText(parsed.authors)
        else
            return ""
        end
    end
    local tokens = {}
    for w in norm:gmatch("%w+") do
        table.insert(tokens, w)
    end
    if #tokens == 0 then return "" end
    table.sort(tokens)
    return table.concat(tokens, " ")
end

local function canonicalTitleKeys(title, entry)
    local raw = tostring(title or "")
    if entry and (not entry.authors or (type(entry.authors) == "table" and #entry.authors == 0) or entry.authors == "") then
        local parsed = getParsedEntryMeta(entry)
        if parsed and parsed.title ~= "" and parsed.authors ~= "" then
            raw = parsed.title
        end
    end
    local full = Matcher.normalizeText(raw)
    if full == "" or full == "untitled" then return "", "" end
    local stripped = raw:gsub("%b()", " "):gsub("%b[]", " ")
    stripped = stripped:gsub(":.*$", "")
    local base = Matcher.normalizeText(stripped)
    if base == "" or base == "untitled" then base = full end
    return full, base
end

local function entryQualityGreater(a, b)
    local a_cf = isCleanFilename(a.filename) and 1 or 0
    local b_cf = isCleanFilename(b.filename) and 1 or 0
    if a_cf ~= b_cf then return a_cf > b_cf end

    local a_au = (type(a.authors) == "table" and #a.authors > 0 and Matcher.normalizeText(a.authors[1]) ~= "")
        or (type(a.authors) == "string" and Matcher.normalizeText(a.authors) ~= "")
    local b_au = (type(b.authors) == "table" and #b.authors > 0 and Matcher.normalizeText(b.authors[1]) ~= "")
        or (type(b.authors) == "string" and Matcher.normalizeText(b.authors) ~= "")
    if a_au ~= b_au then return a_au end

    local a_ct = isCleanTitle(a.title) and 1 or 0
    local b_ct = isCleanTitle(b.title) and 1 or 0
    if a_ct ~= b_ct then return a_ct > b_ct end

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
end

local function mergeEntryFields(keep, dup)
    keep.hashes = keep.hashes or {}
    local sha = dup.hashes and dup.hashes.sha256 or ""
    local pmd5 = dup.hashes and dup.hashes.partial_md5 or ""
    if (not keep.hashes.sha256 or keep.hashes.sha256 == "") and sha ~= "" then
        keep.hashes.sha256 = sha
    end
    if (not keep.hashes.partial_md5 or keep.hashes.partial_md5 == "") and pmd5 ~= "" then
        keep.hashes.partial_md5 = pmd5
    end
    if not keep.has_cover and dup.has_cover then
        keep.has_cover = true
        keep.cover_etag = dup.cover_etag
    end
    if (not keep.authors or (type(keep.authors) == "table" and #keep.authors == 0) or keep.authors == "")
        and dup.authors and ((type(dup.authors) == "table" and #dup.authors > 0) or (type(dup.authors) == "string" and dup.authors ~= "")) then
        keep.authors = dup.authors
    end
    if (not keep.series or keep.series == "") and dup.series and dup.series ~= "" then
        keep.series = dup.series
        keep.series_index = keep.series_index or dup.series_index
    end
end

--- Deduplicates catalog.books in-place by sha256, partial_md5, isbn, calibre_uuid,
-- (filename, size_bytes), canonical (title, author), and folder.
-- Also restores clean deleted entries when paired with an active (number) duplicate,
-- and repairs raw filename titles/authors on surviving entries.
-- @return number removed_count, table dup_folders, number repaired_count
function Sync.deduplicateCatalog(catalog)
    if type(catalog) ~= "table" or type(catalog.books) ~= "table" then
        return 0, {}, 0
    end
    local active_entries = {}
    local deleted_entries = {}
    for id, entry in pairs(catalog.books) do
        if type(entry) == "table" then
            entry.id = entry.id or id
            if entry.deleted then
                table.insert(deleted_entries, entry)
            else
                table.insert(active_entries, entry)
            end
        end
    end
    table.sort(active_entries, entryQualityGreater)

    local by_sha, by_pmd5, by_isbn, by_uuid = {}, {}, {}, {}
    local by_ta, by_ba, by_file, by_tsize, by_folder = {}, {}, {}, {}, {}
    local by_title_author_any = {}
    local id_remap = {}
    local dup_folders = {}
    local removed = 0
    local repaired = 0
    local now_iso = os.date("!%Y-%m-%dT%H:%M:%SZ")

    local function computeMatchKeys(entry)
        local sha = entry.hashes and entry.hashes.sha256 or ""
        local pmd5 = entry.hashes and entry.hashes.partial_md5 or ""
        local isbn = entry.isbn and tostring(entry.isbn):gsub("[^%w]", "") or ""
        local uuid = entry.calibre_uuid and tostring(entry.calibre_uuid) or ""
        local norm_t, base_t = canonicalTitleKeys(entry.title, entry)
        local norm_a = canonicalAuthorKey(entry)
        local ta_key = (norm_t ~= "" and norm_a ~= "") and (norm_t .. "\0" .. norm_a) or nil
        local ba_key = (base_t ~= "" and #base_t >= 4 and norm_a ~= "") and (base_t .. "\0" .. norm_a) or nil
        local fname = entry.filename and tostring(entry.filename):lower() or ""
        local sz = tonumber(entry.size_bytes) or 0
        local file_key = (fname ~= "" and sz > 0) and (fname .. "\0" .. tostring(sz)) or nil
        local tsize_key = (norm_t ~= "" and sz > 0) and (norm_t .. "\0" .. tostring(sz)) or nil
        local folder_key = (entry.folder and entry.folder ~= "") and tostring(entry.folder):lower() or nil
        return {
            sha = sha, pmd5 = pmd5, isbn = isbn, uuid = uuid,
            norm_t = norm_t, base_t = base_t, norm_a = norm_a,
            ta_key = ta_key, ba_key = ba_key, file_key = file_key,
            tsize_key = tsize_key, folder_key = folder_key,
        }
    end

    local function findMatch(k)
        local keep_id = (k.sha ~= "" and by_sha[k.sha])
            or (k.pmd5 ~= "" and by_pmd5[k.pmd5])
            or (k.isbn ~= "" and by_isbn[k.isbn])
            or (k.uuid ~= "" and by_uuid[k.uuid])
            or (k.ta_key and by_ta[k.ta_key])
            or (k.ba_key and by_ba[k.ba_key])
            or (k.file_key and by_file[k.file_key])
            or (k.tsize_key and by_tsize[k.tsize_key])
            or (k.folder_key and by_folder[k.folder_key])
        if not keep_id and k.norm_a == "" and k.base_t ~= "" and (#k.base_t >= 6 or k.base_t:find(" ", 1, true)) then
            keep_id = by_title_author_any[k.base_t]
        end
        return keep_id
    end

    local function indexEntry(entry, k)
        if k.sha ~= "" then by_sha[k.sha] = entry.id end
        if k.pmd5 ~= "" then by_pmd5[k.pmd5] = entry.id end
        if k.isbn ~= "" then by_isbn[k.isbn] = entry.id end
        if k.uuid ~= "" then by_uuid[k.uuid] = entry.id end
        if k.ta_key then by_ta[k.ta_key] = entry.id end
        if k.ba_key then by_ba[k.ba_key] = entry.id end
        if k.file_key then by_file[k.file_key] = entry.id end
        if k.tsize_key then by_tsize[k.tsize_key] = entry.id end
        if k.folder_key then by_folder[k.folder_key] = entry.id end
        if k.base_t ~= "" and not by_title_author_any[k.base_t] then
            by_title_author_any[k.base_t] = entry.id
        end
    end

    for _, entry in ipairs(active_entries) do
        local k = computeMatchKeys(entry)
        local keep_id = findMatch(k)
        if keep_id and keep_id ~= entry.id and catalog.books[keep_id] then
            local keep = catalog.books[keep_id]
            mergeEntryFields(keep, entry)
            entry.deleted = true
            entry.updated_at = now_iso
            id_remap[entry.id] = keep_id
            removed = removed + 1
            if entry.folder and entry.folder ~= "" and entry.folder ~= keep.folder then
                table.insert(dup_folders, entry.folder)
            end
        else
            indexEntry(entry, k)
        end
    end

    -- Restore a clean deleted entry if an active (number)/lower-quality duplicate exists
    table.sort(deleted_entries, entryQualityGreater)
    for _, del_entry in ipairs(deleted_entries) do
        local k = computeMatchKeys(del_entry)
        local active_id = findMatch(k)
        if active_id and active_id ~= del_entry.id and catalog.books[active_id] and not catalog.books[active_id].deleted then
            local cur_active = catalog.books[active_id]
            if isCleanFilename(del_entry.filename) and not isCleanFilename(cur_active.filename) then
                del_entry.deleted = false
                del_entry.updated_at = now_iso
                mergeEntryFields(del_entry, cur_active)
                cur_active.deleted = true
                cur_active.updated_at = now_iso
                id_remap[cur_active.id] = del_entry.id
                removed = removed + 1
                if cur_active.folder and cur_active.folder ~= "" and cur_active.folder ~= del_entry.folder then
                    table.insert(dup_folders, cur_active.folder)
                end
                indexEntry(del_entry, computeMatchKeys(del_entry))
            end
        end
    end

    -- Repair raw filename titles / missing authors on surviving active entries
    for _, entry in pairs(catalog.books) do
        if type(entry) == "table" and not entry.deleted then
            local has_author = (type(entry.authors) == "table" and #entry.authors > 0 and Matcher.normalizeText(entry.authors[1]) ~= "")
                or (type(entry.authors) == "string" and Matcher.normalizeText(entry.authors) ~= "")
            if not has_author or not isCleanTitle(entry.title) then
                local parsed = getParsedEntryMeta(entry)
                if parsed and parsed.title ~= "" and parsed.authors ~= "" then
                    if not has_author then
                        entry.authors = { parsed.authors }
                        repaired = repaired + 1
                    end
                    if not isCleanTitle(entry.title) then
                        entry.title = parsed.title
                        repaired = repaired + 1
                    end
                    if not entry.series_index and parsed.series_index then
                        entry.series_index = parsed.series_index
                    end
                end
            end
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

    return removed, dup_folders, repaired
end

--- Cleans up remote folders under Books/ belonging to deleted tombstones or orphaned concurrent duplicates.
function Sync.cleanupCloudBookFolders(catalog)
    if not Cloud.isConfigured() or not Cloud.listDir or not Cloud.deletePath then return 0 end
    if type(catalog) ~= "table" or type(catalog.books) ~= "table" then return 0 end

    local active_prefixes = {}
    for _, entry in pairs(catalog.books) do
        if type(entry) == "table" and not entry.deleted and entry.folder then
            local prefix = tostring(entry.folder):match("^Books/(.+) %[[^%]]+%]$")
            if prefix then
                active_prefixes[prefix:lower()] = entry.id
            end
        end
    end

    local cleaned = 0
    Cloud.listDir("Books", function(ok, items)
        if not ok or type(items) ~= "table" then return end
        for _, item in ipairs(items) do
            if item.is_dir and item.name then
                local folder_id = item.name:match("%[([%w_%-]+)%]$")
                local entry = folder_id and catalog.books[folder_id]
                local should_delete = false
                if entry and entry.deleted then
                    should_delete = true
                elseif not entry then
                    local prefix = item.name:match("^(.+) %[[^%]]+%]$")
                    if prefix and active_prefixes[prefix:lower()] then
                        should_delete = true
                    end
                end
                if should_delete then
                    local rel = "Books/" .. item.name
                    local ok_d = false
                    Cloud.deletePath(rel, function(d_ok) ok_d = d_ok end)
                    if ok_d then
                        cleaned = cleaned + 1
                        Logger.info("Removed duplicate/deleted cloud folder: " .. rel)
                    end
                end
            end
        end
    end)
    return cleaned
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
        local removed, dup_folders, repaired = Sync.deduplicateCatalog(data)
        if removed > 0 or (repaired and repaired > 0) then
            Logger.info(string.format("Deduplicated %d duplicate(s), repaired %d metadata entry(ies)", removed, repaired or 0))
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
        if not existing_id then
            local fname_l = filename and filename:lower() or ""
            local norm_t, base_t = canonicalTitleKeys(title)
            local norm_a = canonicalAuthorKey({ authors = authors })
            for id, entry in pairs(catalog.books) do
                if type(entry) == "table" and not entry.deleted then
                    local ef = entry.filename and tostring(entry.filename):lower() or ""
                    local et, ebase = canonicalTitleKeys(entry.title, entry)
                    local ea = canonicalAuthorKey(entry)
                    if size_bytes > 0 and tonumber(entry.size_bytes) == size_bytes
                        and ((ef ~= "" and ef == fname_l) or (norm_t ~= "" and et == norm_t)) then
                        existing_id = id
                        break
                    elseif norm_a ~= "" and ea == norm_a
                        and ((norm_t ~= "" and et == norm_t) or (base_t ~= "" and #base_t >= 4 and ebase == base_t)) then
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
        if ok_sc and Scanner and Scanner.readSidecarMeta then
            local sdr = Scanner.readSidecarMeta(filepath)
            local pct = tonumber(sdr and sdr.percent) or 0
            local st_status = normalizeStatusForCloud(sdr and sdr.status, pct)
            if pct > 0 or st_status == "finished" or st_status == "abandoned" then
                local st = Sync.loadLocalState()
                st.progress[book_id] = {
                    book_id = book_id,
                    partial_md5 = partial_md5,
                    percent = (st_status == "finished" and pct < 0.99) and 1 or pct,
                    status = st_status,
                    updated_at = (sdr and sdr.sidecar_mtime and sdr.sidecar_mtime > 0) and sdr.sidecar_mtime or os.time(),
                    device_id = Settings.load().device_id,
                }
                Sync.saveLocalState(st)
                Sync.uploadDeviceProgress(st.progress)
            end
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

--- Returns false on Android where fork() inside a multi-threaded JVM process causes Bionic FORTIFY crashes.
function Sync.canUseSubProcess()
    local ok_d, Device = pcall(require, "device")
    if ok_d and Device and Device.isAndroid and Device:isAndroid() then
        return false
    end
    local ok_fu, ffiUtil = pcall(require, "ffi/util")
    return ok_fu and ffiUtil ~= nil and ffiUtil.runInSubProcess ~= nil
end

local function normalizeStatusForCloud(status, pct)
    if status == "complete" or status == "finished" or (pct or 0) >= 0.99 then
        return "finished"
    elseif status == "abandoned" then
        return "abandoned"
    elseif (pct or 0) > 0 or status == "reading" then
        return "reading"
    end
    return "unread"
end

--- Collects local .sdr progress from device_books for cloud-linked books, updates local_state.lua,
-- uploads progress.json if any entry changed (or device shard is missing), and returns updated merged_progress.
function Sync.collectAndUploadLocalProgress(catalog, device_books, existing_merged)
    local merged = {}
    for k, v in pairs(existing_merged or {}) do
        merged[k] = v
    end
    if type(catalog) ~= "table" or type(catalog.books) ~= "table" then
        return merged, false
    end

    local st = Sync.loadLocalState()
    st.progress = st.progress or {}
    local changed = false
    local cfg = Settings.load()

    for _, b in ipairs(device_books or {}) do
        local cid = b.cloud_id
        if cid and catalog.books[cid] and not catalog.books[cid].deleted then
            local pct = tonumber(b.percent) or 0
            local status = normalizeStatusForCloud(b.status, pct)
            if pct > 0 or status == "finished" or status == "abandoned" then
                local ts = tonumber(b.last_read_ts) or 0
                if ts <= 0 then ts = os.time() end
                local cur = st.progress[cid]
                local cur_pct = cur and (tonumber(cur.percent) or 0) or -1
                local cur_status = cur and cur.status or nil
                local cur_ts = cur and (tonumber(cur.updated_at) or 0) or 0
                if not cur or pct > cur_pct or status ~= cur_status or ts > cur_ts then
                    local rec = {
                        book_id = cid,
                        partial_md5 = b.partial_md5,
                        percent = (status == "finished" and pct < 0.99) and 1 or pct,
                        status = status,
                        updated_at = ts,
                        device_id = cfg.device_id,
                    }
                    st.progress[cid] = rec
                    changed = true
                end
            end
        end
    end

    if changed then
        Sync.saveLocalState(st)
    end

    if changed or (next(st.progress) ~= nil and not existing_merged) then
        Sync.uploadDeviceProgress(st.progress)
    end

    for cid, rec in pairs(st.progress) do
        if type(rec) == "table" then
            local cur = merged[cid]
            local r_ts = tonumber(rec.updated_at) or 0
            local c_ts = cur and (tonumber(cur.updated_at) or 0) or 0
            local r_pct = tonumber(rec.percent) or 0
            local c_pct = cur and (tonumber(cur.percent) or 0) or 0
            if not cur or r_ts > c_ts or (r_ts == c_ts and r_pct > c_pct) then
                local copy = {}
                for k, v in pairs(rec) do copy[k] = v end
                copy.device_id = copy.device_id or cfg.device_id
                merged[cid] = copy
            end
        end
    end

    return merged, changed
end

--- Re-uploads clean v2 cover.jpg files to Cloud for local books after a cover cache migration.
function Sync.reuploadFixedCovers(catalog, device_books, on_progress)
    if not Cloud.isConfigured() or type(catalog) ~= "table" or type(catalog.books) ~= "table" then
        return 0
    end
    local ok_cov, Covers = pcall(require, "nimbus_covers")
    if not ok_cov or not Covers or not Covers.hasPendingCloudCoverReupload or not Covers.hasPendingCloudCoverReupload() then
        return 0
    end

    local targets = {}
    for _, b in ipairs(device_books or {}) do
        if b.cloud_id and b.local_path and catalog.books[b.cloud_id] and not catalog.books[b.cloud_id].deleted then
            local entry = catalog.books[b.cloud_id]
            if entry.folder and entry.folder ~= "" then
                table.insert(targets, { book = b, entry = entry })
            end
        end
    end

    local uploaded = 0
    for idx, t in ipairs(targets) do
        if on_progress then pcall(on_progress, idx, #targets, t.entry.title) end
        local dest = Covers.getCoverFilePath(t.entry)
        if dest and Covers.extractLocalCoverToFile(t.book.local_path, dest) then
            local ok_up = false
            Cloud.uploadFile(t.entry.folder .. "/cover.jpg", dest, function(ok)
                ok_up = ok
            end)
            if ok_up then
                t.entry.has_cover = true
                uploaded = uploaded + 1
            end
        end
    end
    Covers.clearPendingCloudCoverReupload()
    Logger.info(string.format("Re-uploaded %d clean cover(s) to Nimbus Cloud", uploaded))
    return uploaded
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

--- Non-blocking background cloud catalog + progress sync.
-- Uses ffi/util.runInSubProcess on desktop/e-ink, or UIManager:scheduleIn on Android (fork-unsafe).
function Sync.startBackgroundCatalogSync(on_complete, force)
    if not Cloud.isConfigured() or Sync._bg_pid or Sync._bg_running then
        return false
    end
    local now = os.time()
    if not force and Sync._last_bg_sync_ts and (now - Sync._last_bg_sync_ts) < 30 then
        return false
    end

    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_ui or not UIManager then
        return false
    end

    local function runCatalogSyncBody()
        local prev_cat, _, prev_saved_at = Sync.loadCachedCatalog()
        local ok_cat, cat_or_err = false, nil
        Sync.loadCatalog(function(ok, res)
            ok_cat = ok
            cat_or_err = res
        end)
        if not ok_cat then
            return false, tostring(cat_or_err)
        end
        local merged = {}
        Sync.fetchAllDeviceShards("progress.json", function(ok_p, shards)
            if ok_p then
                merged = Merge.mergeProgress(shards)
            end
        end)

        local ok_sc, Scanner = pcall(require, "nimbus_scanner")
        local local_books = (ok_sc and Scanner and Scanner.getCachedLocalBooks)
            and Scanner.getCachedLocalBooks(cat_or_err) or {}
        merged = Sync.collectAndUploadLocalProgress(cat_or_err, local_books, merged)

        local dl_count = 0
        local cfg = Settings.load()
        if cfg.auto_download_new_books ~= false and prev_saved_at and prev_saved_at > 0 then
            local added = Sync.findNewCloudBooks(prev_cat, cat_or_err)
            if #added > 0 then
                local dirs = (ok_sc and Scanner and Scanner.getEffectiveBooksDirs) and Scanner.getEffectiveBooksDirs() or {}
                local base_dir = (dirs[1] and dirs[1] ~= "") and dirs[1] or cfg.download_dir
                local links = Settings.loadBookLinks()
                local local_by_ta = {}
                for _, lb in ipairs(local_books) do
                    local _, lbase = canonicalTitleKeys(lb.title, lb)
                    local la = canonicalAuthorKey(lb)
                    if lbase ~= "" and la ~= "" and lb.local_path then
                        local_by_ta[lbase .. "\0" .. la] = lb.local_path
                    end
                end
                for _, entry in ipairs(added) do
                    if entry.folder and entry.filename and not links.by_id[entry.id] then
                        local _, ebase = canonicalTitleKeys(entry.title, entry)
                        local ea = canonicalAuthorKey(entry)
                        local matched_local = (ebase ~= "" and ea ~= "") and local_by_ta[ebase .. "\0" .. ea] or nil
                        if matched_local then
                            Settings.linkBook(matched_local, entry.id)
                        else
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
        end

        Sync.saveCachedCatalog(cat_or_err, merged)
        return true, dl_count
    end

    Sync._last_bg_sync_ts = now

    if not Sync.canUseSubProcess() then
        Sync._bg_running = true
        UIManager:scheduleIn(0.05, function()
            local ok_run, ok_res, dl_or_err = xpcall(runCatalogSyncBody, debug.traceback)
            Sync._bg_running = false
            if not ok_run then
                Logger.err("Background catalog sync error: " .. tostring(ok_res))
                if on_complete then on_complete(false, tostring(ok_res)) end
            else
                if on_complete then on_complete(ok_res, dl_or_err) end
            end
        end)
        return true
    end

    local ffiUtil = require("ffi/util")
    local pid, parent_read_fd = ffiUtil.runInSubProcess(function(_, child_write_fd)
        local ok_run, ok_res, dl_or_err = xpcall(runCatalogSyncBody, debug.traceback)
        if not ok_run then
            Logger.err("Background catalog sync error: " .. tostring(ok_res))
            if child_write_fd then ffiUtil.writeToFD(child_write_fd, "ERR:" .. tostring(ok_res), true) end
        elseif ok_res then
            if child_write_fd then ffiUtil.writeToFD(child_write_fd, "OK:" .. tostring(dl_or_err or 0), true) end
        else
            if child_write_fd then ffiUtil.writeToFD(child_write_fd, "ERR:" .. tostring(dl_or_err), true) end
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
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_ui or not UIManager then
        local ok_w, res = xpcall(worker_fn, debug.traceback)
        if on_complete then on_complete(ok_w, res) end
        return true, function() end
    end

    local use_subprocess = Sync.canUseSubProcess()
    local ffiUtil = use_subprocess and require("ffi/util") or nil

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
        subprocess = use_subprocess,
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

            if not use_subprocess then
                UIManager:scheduleIn(0.05, function()
                    if canceled then
                        finish_slot()
                        return
                    end
                    local ok_run, res = xpcall(worker_fn, debug.traceback)
                    if not ok_run then
                        Logger.err("Background worker exception: " .. tostring(res))
                    end
                    finish_slot()
                    if on_complete then on_complete(ok_run, res) end
                end)
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
