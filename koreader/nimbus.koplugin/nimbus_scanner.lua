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
            local sidecar_mtime = (lfs and lfs.attributes and lfs.attributes(p, "modification")) or 0
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
                sidecar_mtime = sidecar_mtime,
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

local function restoreLeadingArticle(t)
    local stem, art = t:match("^(.-),%s+(The)$")
    if not stem then stem, art = t:match("^(.-),%s+(the)$") end
    if not stem then stem, art = t:match("^(.-),%s+(An)$") end
    if not stem then stem, art = t:match("^(.-),%s+(an)$") end
    if not stem then stem, art = t:match("^(.-),%s+(A)$") end
    if not stem then stem, art = t:match("^(.-),%s+(a)$") end
    if stem and art then
        local cap_art = art:sub(1, 1):upper() .. art:sub(2):lower()
        return cap_art .. " " .. stem
    end
    return t
end

--- Parses Calibre-style filenames such as:
--   "1 - Cuckoo's Calling, The - Robert Galbraith.epub"
--   "Frankenstein - Mary Shelley (145).epub"
--   "0.5 - Sunrise on the Reaping - Suzanne Collins.epub"
-- @return table { title = string, authors = string, series_index = number|nil }
function Scanner.parseFilenameMetadata(filename)
    local stem = tostring(filename or ""):gsub("%.[^%.]+$", "")
    stem = stem:gsub("^%s+", ""):gsub("%s+$", "")
    stem = stem:gsub("%s*%(%d+%)$", ""):gsub("%s*%-%s*[Cc][Oo][Pp][Yy]$", "")
    stem = stem:gsub("^%s+", ""):gsub("%s+$", "")

    local series_index = nil
    local num_str, after_num = stem:match("^(%d+%.?%d*)%s+%-%s*(.+)$")
    if num_str and after_num then
        local n = tonumber(num_str)
        if n and n <= 50 then
            series_index = n
            stem = after_num
        end
    else
        local int_str, after_int = stem:match("^(%d+)%s+([A-Z].+%s+%-%s+[^%-]+)$")
        if int_str and after_int then
            local n = tonumber(int_str)
            if n and n <= 30 then
                series_index = n
                stem = after_int
            end
        end
    end

    local title_part, author_part = stem:match("^(.+)%s+%-%s+([^%-]+)$")
    if not title_part then
        title_part = stem
        author_part = ""
    end

    title_part = title_part:gsub("_%s+", ": "):gsub("^%s+", ""):gsub("%s+$", "")
    title_part = restoreLeadingArticle(title_part)
    author_part = author_part:gsub("^%s+", ""):gsub("%s+$", "")
    if author_part:lower() == "unknown" or author_part:lower() == "unknown author" then
        author_part = ""
    end

    return {
        title = title_part,
        authors = author_part,
        series_index = series_index,
    }
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
        local series = sdr.series
        local series_index = sdr.series_index
        local language = sdr.language
        if open_doc_info and open_doc_info.filepath == filepath and open_doc_info.props then
            title = open_doc_info.props.title or title
            authors = open_doc_info.props.authors or authors
            series = open_doc_info.props.series or series
            series_index = open_doc_info.props.series_index or series_index
            language = open_doc_info.props.language or language
        end
        if (not title or title == "") or (not authors or authors == "") then
            local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
            if ok_bim and BookInfoManager and BookInfoManager.getBookInfo then
                local ok_bi, info = pcall(function() return BookInfoManager:getBookInfo(filepath, false) end)
                if ok_bi and type(info) == "table" then
                    if not title or title == "" then title = info.title end
                    if not authors or authors == "" then authors = info.authors end
                    if not series or series == "" then series = info.series end
                    if not series_index then series_index = info.series_index end
                    if not language or language == "" then language = info.language end
                end
            end
        end
        local parsed_meta = Scanner.parseFilenameMetadata(filename)
        if not title or title == "" then
            title = (parsed_meta.title ~= "" and parsed_meta.title) or fallback_title
        end
        if not authors or authors == "" then
            authors = parsed_meta.authors
        end
        if not series_index then
            series_index = parsed_meta.series_index
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
            local cat_authors = type(cat_entry.authors) == "table" and table.concat(cat_entry.authors, ", ") or cat_entry.authors
            if cat_entry.metadata_source == "calibre" then
                if cat_entry.title and cat_entry.title ~= "" then title = cat_entry.title end
                if cat_authors and cat_authors ~= "" then authors = cat_authors end
                if cat_entry.series ~= nil then series = cat_entry.series end
                if cat_entry.series_index ~= nil then series_index = cat_entry.series_index end
                if cat_entry.language ~= nil then language = cat_entry.language end
            else
                if not title or title == "" then
                    title = cat_entry.title
                end
                if not authors or authors == "" then
                    authors = cat_authors
                end
            end
        end

        local f_size = (lfs and lfs.attributes and lfs.attributes(filepath, "size")) or 0
        local f_mtime = (lfs and lfs.attributes and lfs.attributes(filepath, "modification")) or 0
        local f_access = (lfs and lfs.attributes and lfs.attributes(filepath, "access")) or 0
        local last_read_ts = math.max(sdr.sidecar_mtime or 0, f_access)

        local item = {
            id = cloud_id or filepath,
            cloud_id = cloud_id,
            is_in_cloud = (cloud_id ~= nil),
            folder = cat_entry and cat_entry.folder or nil,
            has_cover = cat_entry and cat_entry.has_cover or nil,
            cover_etag = cat_entry and cat_entry.cover_etag or nil,
            metadata_source = cat_entry and cat_entry.metadata_source or nil,
            local_path = filepath,
            all_local_paths = { filepath },
            filename = filename,
            format = ext,
            size_bytes = f_size,
            mtime = f_mtime,
            last_read_ts = last_read_ts,
            title = (title and title ~= "") and title or fallback_title,
            authors = authors or "",
            series = series or (cat_entry and cat_entry.series),
            series_index = series_index or (cat_entry and cat_entry.series_index),
            language = language or (cat_entry and cat_entry.language),
            isbn = (cat_entry and cat_entry.metadata_source == "calibre" and cat_entry.isbn) or sdr.isbn or (cat_entry and cat_entry.isbn),
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
            local cat_entry = cid and catalog.books[cid] or nil
            if cat_entry then
                item.folder = cat_entry.folder
                item.has_cover = cat_entry.has_cover
                item.cover_etag = cat_entry.cover_etag
                item.metadata_source = cat_entry.metadata_source
                if cat_entry.metadata_source == "calibre" then
                    if cat_entry.title and cat_entry.title ~= "" then item.title = cat_entry.title end
                    local cat_authors = type(cat_entry.authors) == "table" and table.concat(cat_entry.authors, ", ") or cat_entry.authors
                    if cat_authors and cat_authors ~= "" then item.authors = cat_authors end
                    if cat_entry.series ~= nil then item.series = cat_entry.series end
                    if cat_entry.series_index ~= nil then item.series_index = cat_entry.series_index end
                    if cat_entry.language ~= nil then item.language = cat_entry.language end
                    if cat_entry.isbn ~= nil then item.isbn = cat_entry.isbn end
                end
            else
                item.folder = nil
                item.has_cover = nil
                item.cover_etag = nil
                item.metadata_source = nil
            end
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

function Scanner.getKOReaderSortSettings()
    local collate = "strcoll"
    local reverse_collate = false
    local collate_mixed = false
    if _G.G_reader_settings then
        if _G.G_reader_settings.readSetting then
            collate = _G.G_reader_settings:readSetting("collate") or "strcoll"
        end
        if _G.G_reader_settings.isTrue then
            reverse_collate = _G.G_reader_settings:isTrue("reverse_collate")
            collate_mixed = _G.G_reader_settings:isTrue("collate_mixed")
        end
    end
    return {
        collate = collate,
        reverse = reverse_collate,
        mixed = collate_mixed,
    }
end

local function parseIsoTimestamp(iso)
    if type(iso) ~= "string" then return 0 end
    local y, m, d, hh, mm, ss = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if not y then return 0 end
    return os.time({
        year = tonumber(y),
        month = tonumber(m),
        day = tonumber(d),
        hour = tonumber(hh),
        min = tonumber(mm),
        sec = tonumber(ss),
    }) or 0
end

local function getItemLastRead(item, merged_progress)
    local mp = merged_progress and merged_progress[item.cloud_id or item.id]
    local mp_ts = (mp and tonumber(mp.updated_at)) or 0
    return math.max(tonumber(item.last_read_ts) or 0, mp_ts)
end

local function getItemModTime(item)
    return math.max(tonumber(item.mtime) or 0, parseIsoTimestamp(item.updated_at or item.added_at))
end

local function getItemPercent(item, merged_progress)
    local mp = merged_progress and merged_progress[item.cloud_id or item.id]
    return (mp and tonumber(mp.percent)) or tonumber(item.percent) or 0
end

local function getItemAuthors(item)
    if type(item.authors) == "table" then
        return table.concat(item.authors, ", "):lower()
    end
    return tostring(item.authors or ""):lower()
end

function Scanner.compareItems(a, b, merged_progress, sort_opts)
    sort_opts = sort_opts or Scanner.getKOReaderSortSettings()
    local collate = sort_opts.collate or "strcoll"
    local reverse = sort_opts.reverse == true

    local ta = tostring(a.title or a.name or ""):lower()
    local tb = tostring(b.title or b.name or ""):lower()

    local cmp_res = nil
    if collate == "access" then
        local va = getItemLastRead(a, merged_progress)
        local vb = getItemLastRead(b, merged_progress)
        if va ~= vb then cmp_res = va > vb end
    elseif collate == "date" then
        local va = getItemModTime(a)
        local vb = getItemModTime(b)
        if va ~= vb then cmp_res = va > vb end
    elseif collate == "size" then
        local va = tonumber(a.size_bytes) or 0
        local vb = tonumber(b.size_bytes) or 0
        if va ~= vb then cmp_res = va > vb end
    elseif collate == "type" then
        local fa = tostring(a.format or ""):lower()
        local fb = tostring(b.format or ""):lower()
        if fa ~= fb then cmp_res = fa < fb end
    elseif collate == "percent_unopened_first" then
        local pa = getItemPercent(a, merged_progress)
        local pb = getItemPercent(b, merged_progress)
        local ua = (pa <= 0) and 1 or 0
        local ub = (pb <= 0) and 1 or 0
        if ua ~= ub then
            cmp_res = ua > ub
        elseif pa ~= pb then
            cmp_res = pa > pb
        end
    elseif collate == "percent_unopened_last" or collate == "percent_natural" then
        local pa = getItemPercent(a, merged_progress)
        local pb = getItemPercent(b, merged_progress)
        if pa ~= pb then cmp_res = pa > pb end
    elseif collate == "authors" then
        local aa = getItemAuthors(a)
        local ab = getItemAuthors(b)
        if aa ~= ab then cmp_res = aa < ab end
    elseif collate == "series" then
        local sa = tostring(a.series or ""):lower()
        local sb = tostring(b.series or ""):lower()
        if sa ~= sb then
            if sa == "" then cmp_res = false
            elseif sb == "" then cmp_res = true
            else cmp_res = sa < sb end
        else
            local ia = tonumber(a.series_index) or 0
            local ib = tonumber(b.series_index) or 0
            if ia ~= ib then cmp_res = ia < ib end
        end
    end

    if cmp_res == nil then
        if ta ~= tb then
            cmp_res = ta < tb
        else
            return false
        end
    end

    if reverse then return not cmp_res end
    return cmp_res
end

function Scanner.sortItems(items, merged_progress, sort_opts)
    sort_opts = sort_opts or Scanner.getKOReaderSortSettings()
    table.sort(items, function(a, b)
        return Scanner.compareItems(a, b, merged_progress, sort_opts)
    end)
    return items
end

local function buildFolderItems(folder_buckets, books, merged_progress)
    local sort_opts = Scanner.getKOReaderSortSettings()
    local folders = {}
    for sub_path, list in pairs(folder_buckets) do
        local name = sub_path:match("([^/]+)$") or sub_path
        Scanner.sortItems(list, merged_progress, sort_opts)
        local sample_books = {}
        for i = 1, math.min(4, #list) do
            table.insert(sample_books, list[i])
        end
        local max_last_read, max_mtime, sum_size = 0, 0, 0
        for _, child in ipairs(list) do
            local lr = getItemLastRead(child, merged_progress)
            if lr > max_last_read then max_last_read = lr end
            local mt = getItemModTime(child)
            if mt > max_mtime then max_mtime = mt end
            sum_size = sum_size + (tonumber(child.size_bytes) or 0)
        end
        table.insert(folders, {
            is_folder = true,
            name = name,
            title = name,
            path = sub_path,
            book_count = #list,
            sample_books = sample_books,
            last_read_ts = max_last_read,
            mtime = max_mtime,
            size_bytes = sum_size,
        })
    end

    Scanner.sortItems(folders, merged_progress, sort_opts)
    Scanner.sortItems(books, merged_progress, sort_opts)

    local items = {}
    for _, f in ipairs(folders) do table.insert(items, f) end
    for _, b in ipairs(books) do table.insert(items, b) end
    if sort_opts.mixed then
        Scanner.sortItems(items, merged_progress, sort_opts)
    end
    return folders, books, items
end

--- Lists folders (containing supported books) and books directly inside `dir_path` (or root_dirs).
function Scanner.listFolderContents(dir_path, device_books, root_dirs, merged_progress)
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

    local folders, sorted_books, items = buildFolderItems(folder_buckets, books, merged_progress)

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
function Scanner.listCloudFolderContents(rel_dir, cloud_books, merged_progress)
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

    local folders, sorted_books, items = buildFolderItems(folder_buckets, books, merged_progress)
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
