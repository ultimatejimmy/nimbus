--[[--
nimbus_scanner.lua
Local book discovery, .sdr sidecar metadata parsing, and cloud catalog matching.
--]]

local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end

local Constants = require("nimbus_constants")
local Settings = require("nimbus_settings")
local Hash = require("nimbus_hash")
local Matcher = require("nimbus_matcher")

local Scanner = {}

local EXCLUDED_DIRS = {
    [".git"] = true,
    [".koreader"] = true,
    [".kobo"] = true,
    [".system"] = true,
    [".thumbnails"] = true,
    ["cache"] = true,
    ["backups"] = true,
    ["backup_staging"] = true,
    ["$RECYCLE.BIN"] = true,
    ["System Volume Information"] = true,
}

local function getDataDir()
    return (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
end

function Scanner.isBookFile(filename)
    local ext = tostring(filename or ""):match("%.([^%.]+)$")
    return ext ~= nil and Constants.SUPPORTED_FORMATS[ext:lower()] == true
end

function Scanner.getEffectiveBooksDirs()
    local cfg = Settings.load()
    local raw = {}

    if type(cfg.custom_books_dirs) == "table" and #cfg.custom_books_dirs > 0 then
        for _, d in ipairs(cfg.custom_books_dirs) do
            if type(d) == "string" and d ~= "" then table.insert(raw, d) end
        end
    end

    if #raw == 0 then
        local backup_cfg = Settings.readLuaTable(getDataDir() .. "/settings/backup.lua") or {}
        if type(backup_cfg.custom_books_dirs) == "table" and #backup_cfg.custom_books_dirs > 0 then
            for _, d in ipairs(backup_cfg.custom_books_dirs) do
                if type(d) == "string" and d ~= "" then table.insert(raw, d) end
            end
        elseif type(backup_cfg.custom_books_dir) == "string" and backup_cfg.custom_books_dir ~= "" then
            table.insert(raw, backup_cfg.custom_books_dir)
        end
    end

    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting) == "function" then
        local home_dir = _G.G_reader_settings:readSetting("home_dir")
        if type(home_dir) == "string" and home_dir ~= "" then
            table.insert(raw, home_dir)
        end
    end

    if cfg.download_dir and cfg.download_dir ~= "" then
        table.insert(raw, cfg.download_dir)
    end

    local valid, seen = {}, {}
    for _, p in ipairs(raw) do
        local norm = tostring(p):gsub("\\", "/"):gsub("/+$", "")
        if norm ~= "" and not seen[norm] and lfs and lfs.attributes and lfs.attributes(norm, "mode") == "directory" then
            seen[norm] = true
            table.insert(valid, norm)
        end
    end
    return valid
end

function Scanner.readSidecarMeta(book_path)
    local base = book_path:gsub("%.[^%.]+$", "")
    local ext = (book_path:match("%.([^%.]+)$") or ""):lower()
    local sdr = base .. ".sdr"
    local candidates = {
        sdr .. "/metadata." .. ext .. ".lua",
        sdr .. "/metadata.lua",
    }
    for _, p in ipairs(candidates) do
        local data = Settings.readLuaTable(p)
        if type(data) == "table" then
            local dp = data.doc_props or {}
            local summary = data.summary or {}
            return {
                title = dp.title,
                authors = dp.authors,
                series = dp.series,
                series_index = dp.series_index,
                language = dp.language,
                isbn = dp.isbn,
                percent = tonumber(data.percent_finished) or 0,
                status = summary.status or ((tonumber(data.percent_finished) or 0) >= 0.99 and "finished" or "reading"),
                partial_md5 = data.partial_md5_checksum,
            }
        end
    end
    return {}
end

function Scanner.scanDirectory(dir_path, seen, out)
    if not lfs or not lfs.dir or not dir_path then return end
    if lfs.attributes(dir_path, "mode") ~= "directory" then return end
    for item in lfs.dir(dir_path) do
        if item ~= "." and item ~= ".." and not item:match("^%.") then
            local full = dir_path .. "/" .. item
            local mode = lfs.attributes(full, "mode")
            if mode == "directory" then
                if not item:match("%.sdr$") and not EXCLUDED_DIRS[item] then
                    Scanner.scanDirectory(full, seen, out)
                end
            elseif mode == "file" and Scanner.isBookFile(item) and not seen[full] then
                seen[full] = true
                table.insert(out, full)
            end
        end
    end
end

local _pmd5_cache = {}

local function getCachedPartialMD5(filepath, sdr_pmd5)
    if sdr_pmd5 and sdr_pmd5 ~= "" then
        _pmd5_cache[filepath] = sdr_pmd5
        return sdr_pmd5
    end
    if _pmd5_cache[filepath] then
        return _pmd5_cache[filepath]
    end
    local computed = Hash.partialMD5(filepath)
    if computed then
        _pmd5_cache[filepath] = computed
    end
    return computed
end

local function isDuplicateCopyFilename(filename)
    local stem = tostring(filename or ""):gsub("%.[^%.]+$", "")
    return stem:match("%(%d+%)$") ~= nil or stem:match(" %- copy$") ~= nil
end

function Scanner.scanLocalBooks(catalog, open_doc_info)
    local seen = {}
    local paths = {}

    if open_doc_info and open_doc_info.filepath and not seen[open_doc_info.filepath] then
        local f = io.open(open_doc_info.filepath, "rb")
        if f then
            f:close()
            seen[open_doc_info.filepath] = true
            table.insert(paths, open_doc_info.filepath)
        end
    end

    for _, dir in ipairs(Scanner.getEffectiveBooksDirs()) do
        Scanner.scanDirectory(dir, seen, paths)
    end

    local ok_rh, ReadHistory = pcall(require, "readhistory")
    if ok_rh and ReadHistory and type(ReadHistory.hist) == "table" then
        for _, h in ipairs(ReadHistory.hist) do
            if h.file and not seen[h.file] and Scanner.isBookFile(h.file) then
                local f = io.open(h.file, "rb")
                if f then
                    f:close()
                    seen[h.file] = true
                    table.insert(paths, h.file)
                end
            end
        end
    end

    local has_catalog = (type(catalog) == "table" and type(catalog.books) == "table" and (catalog.version ~= nil or next(catalog.books) ~= nil))
    local links = Settings.loadBookLinks()
    local books = {}
    local by_dedup_key = {}

    for _, filepath in ipairs(paths) do
        local sdr = Scanner.readSidecarMeta(filepath)
        local filename = filepath:match("([^/\\]+)$") or filepath
        local ext = (filename:match("%.([^%.]+)$") or "epub"):lower()
        local fallback_title = filename:gsub("%.[^%.]+$", "")

        local title = sdr.title
        local authors = sdr.authors
        if open_doc_info and open_doc_info.filepath == filepath and open_doc_info.props then
            title = open_doc_info.props.title or title
            authors = open_doc_info.props.authors or authors
        end

        local pmd5 = getCachedPartialMD5(filepath, sdr.partial_md5)
        local cloud_id = links.by_path[filepath]
        if has_catalog then
            if cloud_id and (not catalog.books[cloud_id] or catalog.books[cloud_id].deleted) then
                cloud_id = nil
            end
            if not cloud_id then
                cloud_id = Matcher.resolve(filepath, catalog, {
                    partial_md5 = pmd5,
                    title = title or fallback_title,
                    authors = authors,
                    isbn = sdr.isbn,
                })
            end
        end

        local cat_entry = (cloud_id and catalog and catalog.books and catalog.books[cloud_id]) or nil
        if cat_entry then
            if not title or title == "" then
                title = cat_entry.title
            end
            if not authors or authors == "" then
                authors = type(cat_entry.authors) == "table" and table.concat(cat_entry.authors, ", ") or cat_entry.authors
            end
        end

        local item = {
            id = cloud_id or filepath,
            cloud_id = cloud_id,
            is_in_cloud = (cloud_id ~= nil),
            local_path = filepath,
            all_local_paths = { filepath },
            filename = filename,
            format = ext,
            title = (title and title ~= "") and title or fallback_title,
            authors = authors or "",
            series = sdr.series or (cat_entry and cat_entry.series),
            series_index = sdr.series_index or (cat_entry and cat_entry.series_index),
            language = sdr.language or (cat_entry and cat_entry.language),
            isbn = sdr.isbn or (cat_entry and cat_entry.isbn),
            percent = sdr.percent or 0,
            status = sdr.status,
            partial_md5 = pmd5,
        }

        local dedup_key = cloud_id or (pmd5 and ("md5:" .. pmd5)) or filepath
        local existing_idx = by_dedup_key[dedup_key]
        if not existing_idx then
            table.insert(books, item)
            by_dedup_key[dedup_key] = #books
        else
            local existing = books[existing_idx]
            table.insert(existing.all_local_paths, filepath)
            local replace = false
            if isDuplicateCopyFilename(existing.filename) and not isDuplicateCopyFilename(item.filename) then
                replace = true
            elseif (item.percent or 0) > (existing.percent or 0) then
                replace = true
            end
            if replace then
                item.all_local_paths = existing.all_local_paths
                books[existing_idx] = item
                if cloud_id then
                    Settings.linkBook(item.local_path, cloud_id)
                end
            end
        end
    end

    table.sort(books, function(a, b)
        return tostring(a.title or ""):lower() < tostring(b.title or ""):lower()
    end)

    Scanner._mem_cache = books
    Settings.writeLuaTable(Settings.getNimbusDir() .. "/local_books_cache.lua", {
        saved_at = os.time(),
        books = books,
    })
    return books
end

function Scanner.invalidateCache()
    Scanner._mem_cache = nil
    os.remove(Settings.getNimbusDir() .. "/local_books_cache.lua")
end

--- Fast cached local books lookup (<5ms): avoids filesystem walk & hashes on Home Screen open.
function Scanner.getCachedLocalBooks(catalog, open_doc_info)
    local cached = Scanner._mem_cache
    if not cached then
        local disk = Settings.readLuaTable(Settings.getNimbusDir() .. "/local_books_cache.lua")
        if type(disk) == "table" and type(disk.books) == "table" and #disk.books > 0 then
            cached = disk.books
            Scanner._mem_cache = cached
        end
    end
    if not cached then
        return Scanner.scanLocalBooks(catalog, open_doc_info)
    end

    local has_catalog = (type(catalog) == "table" and type(catalog.books) == "table" and next(catalog.books) ~= nil)
    local links = Settings.loadBookLinks()
    for _, item in ipairs(cached) do
        local cid = links.by_path[item.local_path] or item.cloud_id
        if has_catalog then
            if cid and (not catalog.books[cid] or catalog.books[cid].deleted) then
                cid = nil
            end
            if not cid and item.partial_md5 then
                for id, entry in pairs(catalog.books) do
                    if not entry.deleted and entry.hashes and entry.hashes.partial_md5 == item.partial_md5 then
                        cid = id
                        break
                    end
                end
            end
            item.cloud_id = cid
            item.is_in_cloud = (cid ~= nil)
            item.id = cid or item.local_path
        end
        if open_doc_info and open_doc_info.filepath == item.local_path then
            local sdr = Scanner.readSidecarMeta(item.local_path)
            if sdr.percent then item.percent = sdr.percent end
            if sdr.status then item.status = sdr.status end
        end
    end
    return cached
end

--- Returns the relative subdirectory of `filepath` under `root_dirs` (e.g. "Beeline" or "").
function Scanner.getRelativeDir(filepath, root_dirs)
    if not filepath or filepath == "" then return "" end
    local norm_fp = tostring(filepath):gsub("\\", "/")
    local dir_part = norm_fp:match("^(.*)/[^/]+$") or ""
    root_dirs = root_dirs or Scanner.getEffectiveBooksDirs()
    for _, r in ipairs(root_dirs) do
        local nr = tostring(r):gsub("\\", "/"):gsub("/+$", "")
        if nr ~= "" then
            if dir_part == nr then
                return ""
            elseif dir_part:sub(1, #nr + 1) == (nr .. "/") then
                return dir_part:sub(#nr + 2)
            end
        end
    end
    return ""
end

local function buildFolderItems(folder_buckets, books)
    local folders = {}
    for sub_path, list in pairs(folder_buckets) do
        local name = sub_path:match("([^/]+)$") or sub_path
        table.sort(list, function(a, b)
            return tostring(a.title or ""):lower() < tostring(b.title or ""):lower()
        end)
        local sample_books = {}
        for i = 1, math.min(4, #list) do
            table.insert(sample_books, list[i])
        end
        table.insert(folders, {
            is_folder = true,
            name = name,
            title = name,
            path = sub_path,
            book_count = #list,
            sample_books = sample_books,
        })
    end

    local collate_mixed = false
    local reverse_collate = false
    if _G.G_reader_settings and _G.G_reader_settings.isTrue then
        collate_mixed = _G.G_reader_settings:isTrue("collate_mixed")
        reverse_collate = _G.G_reader_settings:isTrue("reverse_collate")
    end

    local function cmp(a, b)
        local ta = tostring(a.title or a.name or ""):lower()
        local tb = tostring(b.title or b.name or ""):lower()
        if reverse_collate then return ta > tb end
        return ta < tb
    end

    table.sort(folders, cmp)
    table.sort(books, cmp)

    local items = {}
    for _, f in ipairs(folders) do table.insert(items, f) end
    for _, b in ipairs(books) do table.insert(items, b) end
    if collate_mixed then
        table.sort(items, cmp)
    end
    return folders, books, items
end

--- Lists folders (containing supported books) and books directly inside `dir_path` (or root_dirs).
function Scanner.listFolderContents(dir_path, device_books, root_dirs)
    root_dirs = root_dirs or Scanner.getEffectiveBooksDirs()
    if not dir_path or dir_path == "" then
        dir_path = root_dirs[1]
    end
    if not dir_path then
        return { folders = {}, books = {}, items = {}, can_go_up = false, parent_dir = nil, current_dir = nil, current_label = "" }
    end

    local norm_cur = tostring(dir_path):gsub("\\", "/"):gsub("/+$", "")
    local books = {}
    local prefix = norm_cur .. "/"
    local folder_buckets = {}

    for _, b in ipairs(device_books or {}) do
        local lp = b.local_path
        if lp and lp:sub(1, #prefix) == prefix then
            local rel = lp:sub(#prefix + 1)
            local sub = rel:match("^([^/]+)/")
            if sub then
                local sub_path = norm_cur .. "/" .. sub
                folder_buckets[sub_path] = folder_buckets[sub_path] or {}
                table.insert(folder_buckets[sub_path], b)
            else
                table.insert(books, b)
            end
        end
    end

    local folders, sorted_books, items = buildFolderItems(folder_buckets, books)

    local is_root = false
    for _, r in ipairs(root_dirs) do
        local nr = tostring(r):gsub("\\", "/"):gsub("/+$", "")
        if nr == norm_cur then is_root = true; break end
    end
    local parent_dir = nil
    if not is_root then
        parent_dir = norm_cur:match("^(.*)/[^/]+$")
    end

    return {
        folders = folders,
        books = sorted_books,
        items = items,
        can_go_up = (not is_root and parent_dir ~= nil),
        parent_dir = parent_dir,
        current_dir = norm_cur,
        current_label = norm_cur:match("([^/]+)$") or norm_cur,
    }
end

--- Lists virtual cloud folders (from `entry.relative_dir`) and books inside `rel_dir` ("" = root).
function Scanner.listCloudFolderContents(rel_dir, cloud_books)
    local norm_cur = tostring(rel_dir or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
    local books = {}
    local folder_buckets = {}
    local prefix = (norm_cur == "") and "" or (norm_cur .. "/")

    for _, b in ipairs(cloud_books or {}) do
        local b_rel = tostring(b.relative_dir or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
        if b_rel == norm_cur then
            table.insert(books, b)
        elseif prefix == "" or b_rel:sub(1, #prefix) == prefix then
            local rest = (prefix == "") and b_rel or b_rel:sub(#prefix + 1)
            local sub = rest:match("^([^/]+)")
            if sub and sub ~= "" then
                local sub_path = (norm_cur == "") and sub or (norm_cur .. "/" .. sub)
                folder_buckets[sub_path] = folder_buckets[sub_path] or {}
                table.insert(folder_buckets[sub_path], b)
            end
        end
    end

    local folders, sorted_books, items = buildFolderItems(folder_buckets, books)
    local can_go_up = (norm_cur ~= "")
    local parent_dir = can_go_up and (norm_cur:match("^(.*)/[^/]+$") or "") or nil

    return {
        folders = folders,
        books = sorted_books,
        items = items,
        can_go_up = can_go_up,
        parent_dir = parent_dir,
        current_dir = norm_cur,
        current_label = norm_cur:match("([^/]+)$") or norm_cur,
    }
end

return Scanner
