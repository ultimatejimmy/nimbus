--[[--
nimbus_covers.lua
Cover image caching, local book cover extraction, async cloud fetching,
and aspect-filled widget rendering for Nimbus.
--]]

local ok_util, util = pcall(require, "util")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end

local Settings = require("nimbus_settings")
local Cloud = require("nimbus_cloud")
local Conductor = require("nimbus_conductor")
local Hash = require("nimbus_hash")

local Covers = {}

local function fileExists(path)
    if not path then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function getEtagPath(cover_path)
    return cover_path and (cover_path .. ".etag") or nil
end

local function readEtag(cover_path)
    local ep = getEtagPath(cover_path)
    if not ep then return nil end
    local f = io.open(ep, "rb")
    if not f then return nil end
    local val = f:read("*a")
    f:close()
    if not val then return nil end
    return val:gsub("%s+$", "")
end

local function writeEtag(cover_path, etag)
    local ep = getEtagPath(cover_path)
    if not ep then return end
    if type(etag) ~= "string" or etag == "" then
        pcall(os.remove, ep)
        return
    end
    local f = io.open(ep, "wb")
    if f then
        f:write(etag)
        f:close()
    end
end

Covers.writeEtag = writeEtag

local function isCalibreCoverEtag(etag)
    return type(etag) == "string" and etag:sub(1, 7) == "v2_cal_"
end

local function makeCacheKey(entry)
    if not entry then return nil end
    local key = entry.cloud_id or entry.id or entry.local_path
    if not key or key == "" then return nil end
    key = tostring(key)
    if key:find("[/\\:]") or #key > 48 then
        return Hash.sha256String(key):sub(1, 24)
    end
    return key:gsub("[^%w%-_]", "_")
end

local _cache_v2_checked = false

local function ensureCoverCacheVersion(dir)
    if _cache_v2_checked or not dir or dir == "" then return end
    _cache_v2_checked = true
    local marker = dir .. "/.cache_v2"
    if fileExists(marker) then return end
    if lfs and lfs.dir then
        pcall(function()
            for name in lfs.dir(dir) do
                if name:sub(-4) == ".jpg" or name:sub(-4) == ".tmp" then
                    os.remove(dir .. "/" .. name)
                end
            end
        end)
    end
    local mf = io.open(marker, "wb")
    if mf then mf:write("v2\n"); mf:close() end
    local pf = io.open(dir .. "/.reupload_pending", "wb")
    if pf then pf:write("1\n"); pf:close() end
end

function Covers.hasPendingCloudCoverReupload()
    local dir = Settings.getCoversCacheDir()
    return fileExists(dir .. "/.reupload_pending")
end

function Covers.clearPendingCloudCoverReupload()
    local dir = Settings.getCoversCacheDir()
    pcall(os.remove, dir .. "/.reupload_pending")
end

local function mkdirRecursive(dir)
    if not dir or dir == "" then return end
    if ok_util and util and util.makePath then
        util.makePath(dir)
        return
    end
    if not lfs or not lfs.mkdir then return end
    local acc = dir:sub(1, 1) == "/" and "/" or ""
    for part in dir:gmatch("[^/]+") do
        acc = (acc == "" or acc == "/") and (acc .. part) or (acc .. "/" .. part)
        pcall(lfs.mkdir, acc)
    end
end

function Covers.getCoverFilePath(entry)
    local key = makeCacheKey(entry)
    if not key then return nil end
    local dir = Settings.getCoversCacheDir()
    mkdirRecursive(dir)
    ensureCoverCacheVersion(dir)
    local is_v2 = type(entry.cover_etag) == "string" and entry.cover_etag:sub(1, 3) == "v2_"
    if is_v2 then
        local v2_path = dir .. "/" .. key .. "_v2.jpg"
        local old_path = dir .. "/" .. key .. ".jpg"
        if not fileExists(v2_path) and fileExists(old_path) then
            pcall(os.remove, old_path)
        end
        return v2_path
    end
    return dir .. "/" .. key .. ".jpg"
end

function Covers.isCoverCacheStale(entry, path)
    if not entry or not path or type(entry.cover_etag) ~= "string" or entry.cover_etag == "" then
        return false
    end
    local stored = readEtag(path)
    if stored and stored ~= "" then
        return stored ~= entry.cover_etag
    end
    return isCalibreCoverEtag(entry.cover_etag)
end

function Covers.getCachedCoverPath(entry)
    local path = Covers.getCoverFilePath(entry)
    if path and fileExists(path) then
        if Covers.isCoverCacheStale(entry, path) then
            pcall(os.remove, path)
            pcall(os.remove, getEtagPath(path))
            if Covers.invalidateMemoryCacheForPath then
                Covers.invalidateMemoryCacheForPath(path)
            end
            return nil
        end
        return path
    end
    return nil
end

function Covers.pruneStaleCovers(catalog_books)
    if type(catalog_books) ~= "table" then return 0 end
    local pruned = 0
    for _, entry in pairs(catalog_books) do
        if type(entry) == "table" and not entry.deleted and type(entry.cover_etag) == "string" and entry.cover_etag ~= "" then
            local path = Covers.getCoverFilePath(entry)
            if path and fileExists(path) and Covers.isCoverCacheStale(entry, path) then
                pcall(os.remove, path)
                pcall(os.remove, getEtagPath(path))
                if Covers.invalidateMemoryCacheForPath then
                    Covers.invalidateMemoryCacheForPath(path)
                end
                pruned = pruned + 1
            end
        end
    end
    return pruned
end

--- Normalizes any BlitBuffer to a tightly-packed TYPE_BBRGB24 buffer (flattening alpha onto white).
-- Returns (bb, should_free_bb).
local function normalizeToRGB24(src_bb)
    if not src_bb then return nil, false end
    local ok_bb_mod, Blitbuffer = pcall(require, "ffi/blitbuffer")
    if not ok_bb_mod or not Blitbuffer or not Blitbuffer.new or not Blitbuffer.TYPE_BBRGB24 then
        return src_bb, false
    end
    local w = src_bb.getWidth and src_bb:getWidth()
    local h = src_bb.getHeight and src_bb:getHeight()
    if not w or not h or w <= 0 or h <= 0 then
        return src_bb, false
    end
    local bb_type = src_bb.getType and src_bb:getType()
    local ok_st, stride = pcall(function() return tonumber(src_bb.stride) end)
    if bb_type == Blitbuffer.TYPE_BBRGB24 and (not ok_st or not stride or stride == w * 3) then
        return src_bb, false
    end

    local ok_new, clean_bb = pcall(Blitbuffer.new, w, h, Blitbuffer.TYPE_BBRGB24)
    if not ok_new or not clean_bb then
        return src_bb, false
    end
    pcall(function() clean_bb:fill(Blitbuffer.COLOR_WHITE) end)
    local has_alpha = (bb_type == Blitbuffer.TYPE_BBRGB32 or bb_type == Blitbuffer.TYPE_BB8A)
    local ok_blit = false
    if has_alpha and clean_bb.alphablitFrom then
        ok_blit = pcall(function() clean_bb:alphablitFrom(src_bb, 0, 0, 0, 0, w, h) end)
    end
    if not ok_blit and clean_bb.blitFrom then
        ok_blit = pcall(function() clean_bb:blitFrom(src_bb, 0, 0, 0, 0, w, h) end)
    end
    if not ok_blit then
        if clean_bb.free then pcall(function() clean_bb:free() end) end
        return src_bb, false
    end
    return clean_bb, true
end

Covers._normalizeToRGB24 = normalizeToRGB24

local function writeScaledBlitBuffer(orig_bb, dest_path)
    if not orig_bb or not dest_path then return false end
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    local orig_w = orig_bb.getWidth and orig_bb:getWidth()
    local orig_h = orig_bb.getHeight and orig_bb:getHeight()
    if not orig_w or not orig_h or orig_w <= 0 or orig_h <= 0 then
        return false
    end

    local norm_bb, free_norm = normalizeToRGB24(orig_bb)
    local target_bb = norm_bb
    local scaled_bb = nil
    if ok_ri and RenderImage and orig_w > 400 then
        local new_w = 400
        local new_h = math.max(1, math.floor(orig_h * (400 / orig_w)))
        local ok_s, res_bb = pcall(function()
            return RenderImage:scaleBlitBuffer(norm_bb, new_w, new_h, false)
        end)
        if ok_s and res_bb then
            local s_norm, free_s_norm = normalizeToRGB24(res_bb)
            if free_s_norm and res_bb.free then
                pcall(function() res_bb:free() end)
            end
            scaled_bb = s_norm
            target_bb = scaled_bb
        end
    end

    local tmp = dest_path .. ".tmp"
    local wrote = false
    if target_bb.writeToFile then
        local ok_w = pcall(function()
            wrote = target_bb:writeToFile(tmp, "jpg", 85)
        end)
        if not ok_w or not wrote then
            pcall(function() wrote = target_bb:writeToFile(tmp, "png") end)
        end
    elseif target_bb.writeJPG then
        pcall(function() wrote = target_bb:writeJPG(tmp, 85) end)
    elseif target_bb.writePNG then
        pcall(function() wrote = target_bb:writePNG(tmp) end)
    end

    if scaled_bb and scaled_bb ~= norm_bb and scaled_bb.free then
        pcall(function() scaled_bb:free() end)
    end
    if free_norm and norm_bb and norm_bb.free then
        pcall(function() norm_bb:free() end)
    end

    if wrote and fileExists(tmp) then
        os.remove(dest_path)
        if os.rename(tmp, dest_path) then
            return true
        end
    end
    os.remove(tmp)
    return false
end

--- Extracts a cover thumbnail from a local ebook file and saves it to dest_path.
-- Pass opts = { subprocess_safe = true } when running in a forked subprocess to avoid
-- touching open_doc or BookInfoManager's SQLite handle.
function Covers.extractLocalCoverToFile(filepath, dest_path, open_doc, force_overwrite, opts)
    if not filepath or not dest_path or not fileExists(filepath) then
        return false
    end
    if not force_overwrite and fileExists(dest_path) then
        return true
    end
    local subprocess_safe = type(opts) == "table" and opts.subprocess_safe == true

    -- 1. Check custom cover in .sdr sidecar
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_ds and DocSettings and DocSettings.findCustomCoverFile then
        local ok_cc, custom_cover = pcall(DocSettings.findCustomCoverFile, DocSettings, filepath)
        if ok_cc and type(custom_cover) == "string" and fileExists(custom_cover) then
            local ok_ri, RenderImage = pcall(require, "ui/renderimage")
            if ok_ri and RenderImage then
                local ok_bb, bb = pcall(function() return RenderImage:renderImageFile(custom_cover, false) end)
                if ok_bb and bb then
                    local ok_w = writeScaledBlitBuffer(bb, dest_path)
                    if bb.free then pcall(function() bb:free() end) end
                    if ok_w then return true end
                end
            end
        end
    end

    -- 2. If currently open in Reader, use the active document directly
    if not subprocess_safe and open_doc and open_doc.file == filepath and open_doc.getCoverPageImage then
        local ok_bb, bb = pcall(function() return open_doc:getCoverPageImage() end)
        if ok_bb and bb then
            local ok_w = writeScaledBlitBuffer(bb, dest_path)
            if bb.free then pcall(function() bb:free() end) end
            if ok_w then return true end
        end
    end

    -- 3. Check KOReader's BookInfoManager cache only if it holds a full-color, >=250px buffer
    if not subprocess_safe then
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_bim and BookInfoManager and BookInfoManager.getBookInfo then
            local ok_bi, info = pcall(function() return BookInfoManager:getBookInfo(filepath, true) end)
            if ok_bi and type(info) == "table" and info.cover_bb then
                local ok_bb_mod, Blitbuffer = pcall(require, "ffi/blitbuffer")
                local bb = info.cover_bb
                local bb_type = bb.getType and bb:getType()
                local bb_w = bb.getWidth and bb:getWidth() or 0
                local is_color = ok_bb_mod and Blitbuffer and (bb_type == Blitbuffer.TYPE_BBRGB24 or bb_type == Blitbuffer.TYPE_BBRGB32)
                local ok_w = false
                if is_color and bb_w >= 250 then
                    ok_w = writeScaledBlitBuffer(bb, dest_path)
                end
                if bb.free then pcall(function() bb:free() end) end
                if ok_w then return true end
            end
        end
    end

    -- 4. Open document metadata-only via DocumentRegistry
    local ok_dr, DocumentRegistry = pcall(require, "document/documentregistry")
    if ok_dr and DocumentRegistry and DocumentRegistry.openDocument then
        local ok_doc, doc = pcall(function() return DocumentRegistry:openDocument(filepath) end)
        if ok_doc and doc then
            if doc.loadDocument then
                pcall(function() doc:loadDocument(false) end)
            end
            local ok_bb, bb = pcall(function() return doc.getCoverPageImage and doc:getCoverPageImage() end)
            pcall(function() if doc.close then doc:close() end end)
            if ok_bb and bb then
                local ok_w = writeScaledBlitBuffer(bb, dest_path)
                if bb.free then pcall(function() bb:free() end) end
                collectgarbage("step", 100)
                if ok_w then return true end
            end
        end
    end

    return false
end

function Covers.fetchCover(entry, cb, open_doc)
    if not entry then
        if cb then cb(nil) end
        return nil
    end
    local cached = Covers.getCachedCoverPath(entry)
    if cached then
        if cb then cb(cached) end
        return cached
    end

    local dest = Covers.getCoverFilePath(entry)
    if not dest then
        if cb then cb(nil) end
        return nil
    end

    local function tryLocalFallback()
        if entry.local_path and Covers.extractLocalCoverToFile(entry.local_path, dest, open_doc) then
            writeEtag(dest, entry.cover_etag)
            if cb then cb(dest) end
            return dest
        end
        if cb then cb(nil) end
        return nil
    end

    local prefer_cloud = isCalibreCoverEtag(entry.cover_etag) and entry.has_cover and entry.folder
    if not prefer_cloud and entry.local_path and Covers.extractLocalCoverToFile(entry.local_path, dest, open_doc) then
        writeEtag(dest, entry.cover_etag)
        if cb then cb(dest) end
        return dest
    end

    if not entry.has_cover or not entry.folder then
        if prefer_cloud then
            return tryLocalFallback()
        end
        if cb then cb(nil) end
        return nil
    end

    local tmp = dest .. ".tmp"
    Cloud.downloadFile(entry.folder .. "/cover.jpg", tmp, function(ok)
        if ok then
            os.remove(dest)
            writeEtag(dest, entry.cover_etag)
            if os.rename(tmp, dest) then
                if cb then cb(dest) end
                return
            end
        end
        os.remove(tmp)
        if prefer_cloud then
            tryLocalFallback()
        elseif cb then
            cb(nil)
        end
    end, { total_timeout = 15 })
end

local _fetch_queue = {}
local _fetch_running = false
local _fetch_settle_timer = nil
local _fetch_poll_timer = nil
local _fetch_subproc = nil -- { pid, read_fd, tmp_paths, pending_jobs }
local _fetch_gen = 0
local _decode_queue = {}
local _decode_timer = nil

local function canUseSubProcess()
    local ok_d, Device = pcall(require, "device")
    if ok_d and Device and Device.isAndroid and Device:isAndroid() then
        return false
    end
    local ok_fu, ffiUtil = pcall(require, "ffi/util")
    return ok_fu and ffiUtil ~= nil and ffiUtil.runInSubProcess ~= nil
end

local function finishReapedSubProcess(sp, ffiUtil)
    if sp.read_fd and ffiUtil and ffiUtil.readAllFromFD then
        pcall(ffiUtil.readAllFromFD, sp.read_fd)
    end
    for _, tmp in ipairs(sp.tmp_paths or {}) do
        pcall(os.remove, tmp)
    end
end

local function cleanupSubProcess()
    local sp = _fetch_subproc
    if not sp then return end
    _fetch_subproc = nil
    if sp.done_slot then
        local d = sp.done_slot
        sp.done_slot = nil
        pcall(d)
    end
    local ok_fu, ffiUtil = pcall(require, "ffi/util")
    if not ok_fu or not ffiUtil then
        finishReapedSubProcess(sp, nil)
        return
    end
    if ffiUtil.terminateSubProcess then
        pcall(ffiUtil.terminateSubProcess, sp.pid)
    end
    local ok_done, done = pcall(function()
        return ffiUtil.isSubProcessDone and ffiUtil.isSubProcessDone(sp.pid, false)
    end)
    if ok_done and done then
        finishReapedSubProcess(sp, ffiUtil)
        return
    end
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.scheduleIn then
        local reap_attempts = 0
        local function reapAsync()
            reap_attempts = reap_attempts + 1
            local ok_d, is_done = pcall(function()
                return ffiUtil.isSubProcessDone and ffiUtil.isSubProcessDone(sp.pid, false)
            end)
            if (ok_d and is_done) or reap_attempts >= 40 then
                finishReapedSubProcess(sp, ffiUtil)
                return
            end
            UIManager:scheduleIn(0.25, reapAsync)
        end
        UIManager:scheduleIn(0.25, reapAsync)
    else
        finishReapedSubProcess(sp, ffiUtil)
    end
end

function Covers.clearFetchQueue()
    _fetch_gen = _fetch_gen + 1
    _fetch_queue = {}
    _decode_queue = {}
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.unschedule then
        if _fetch_settle_timer then
            pcall(UIManager.unschedule, UIManager, _fetch_settle_timer)
            _fetch_settle_timer = nil
        end
        if _fetch_poll_timer then
            pcall(UIManager.unschedule, UIManager, _fetch_poll_timer)
            _fetch_poll_timer = nil
        end
        if _decode_timer then
            pcall(UIManager.unschedule, UIManager, _decode_timer)
            _decode_timer = nil
        end
    end
    cleanupSubProcess()
end

local function pumpFallbackQueue(expected_gen)
    if expected_gen ~= _fetch_gen or _fetch_running then return end
    local job = table.remove(_fetch_queue, 1)
    if not job then return end
    _fetch_running = true
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local ok_call, err = pcall(Covers.fetchCover, job.entry, function(path)
        _fetch_running = false
        if expected_gen == _fetch_gen and job.cb then
            pcall(job.cb, path)
        end
        if expected_gen == _fetch_gen and #_fetch_queue > 0 then
            if ok_ui and UIManager and UIManager.scheduleIn then
                UIManager:scheduleIn(0.2, function() pumpFallbackQueue(expected_gen) end)
            else
                pumpFallbackQueue(expected_gen)
            end
        end
    end, job.open_doc)
    if not ok_call then
        _fetch_running = false
        if expected_gen == _fetch_gen and #_fetch_queue > 0 then
            if ok_ui and UIManager and UIManager.scheduleIn then
                UIManager:scheduleIn(0.2, function() pumpFallbackQueue(expected_gen) end)
            end
        end
    end
end

local function startSubProcessBatch(jobs, expected_gen)
    local ok_fu, ffiUtil = pcall(require, "ffi/util")
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_fu or not ffiUtil or not ffiUtil.runInSubProcess or not ok_ui or not UIManager then
        for _, j in ipairs(jobs) do table.insert(_fetch_queue, j) end
        pumpFallbackQueue(expected_gen)
        return
    end

    local pending_jobs = {}
    local tmp_paths = {}
    local dl_specs = {}
    for _, job in ipairs(jobs) do
        local e = job.entry
        local dest = Covers.getCoverFilePath(e)
        if dest and e and (e.local_path or (e.has_cover and e.folder)) then
            table.insert(pending_jobs, { dest = dest, cb = job.cb, done = false })
            table.insert(dl_specs, {
                local_path = e.local_path,
                has_cover = e.has_cover,
                folder = e.folder,
                cover_etag = e.cover_etag,
                dest = dest,
            })
        end
    end
    if #dl_specs == 0 then return end

    Conductor.requestSlot({
        plugin = "nimbus",
        task = "fetch_covers",
        priority = "interactive_bg",
        dedupe_key = "nimbus:fetch_covers",
        subprocess = true,
        cancel = function()
            cleanupSubProcess()
        end,
        on_rejected = function()
            -- Deferred due to low_memory or suspend; UI will re-enqueue on next render.
        end,
        run = function(done)
            if expected_gen ~= _fetch_gen then
                done()
                return
            end

            local pid, parent_read_fd = ffiUtil.runInSubProcess(function(child_pid, child_write_fd)
                pcall(function()
                    local CoversChild = require("nimbus_covers")
                    local CloudFS = require("nimbus_cloud")
                    for _, spec in ipairs(dl_specs) do
                        local tmp = spec.dest .. "." .. tostring(child_pid or "bg") .. ".tmp"
                        local prefer_cloud = isCalibreCoverEtag(spec.cover_etag) and spec.has_cover and spec.folder
                        local saved = false

                        local function tryDownloadCloud()
                            if not (spec.has_cover and spec.folder) then return false end
                            local ok_dl = false
                            CloudFS.downloadFile(spec.folder .. "/cover.jpg", tmp, function(ok)
                                if ok then
                                    os.remove(spec.dest)
                                    writeEtag(spec.dest, spec.cover_etag)
                                    if os.rename(tmp, spec.dest) then
                                        ok_dl = true
                                    else
                                        os.remove(tmp)
                                    end
                                else
                                    os.remove(tmp)
                                end
                            end, { total_timeout = 15 })
                            return ok_dl
                        end

                        local function tryExtractLocal()
                            if not (spec.local_path and CoversChild and CoversChild.extractLocalCoverToFile) then
                                return false
                            end
                            local ok_ext = CoversChild.extractLocalCoverToFile(spec.local_path, tmp, nil, true, { subprocess_safe = true })
                            if ok_ext and fileExists(tmp) then
                                os.remove(spec.dest)
                                writeEtag(spec.dest, spec.cover_etag)
                                if os.rename(tmp, spec.dest) then
                                    return true
                                end
                            end
                            os.remove(tmp)
                            return false
                        end

                        if prefer_cloud then
                            saved = tryDownloadCloud()
                            if not saved then
                                saved = tryExtractLocal()
                            end
                        else
                            saved = tryExtractLocal()
                            if not saved then
                                saved = tryDownloadCloud()
                            end
                        end
                    end
                end)
                if child_write_fd then
                    pcall(ffiUtil.writeToFD, child_write_fd, "DONE", true)
                end
            end, true)

            if not pid then
                done()
                for _, j in ipairs(jobs) do table.insert(_fetch_queue, j) end
                pumpFallbackQueue(expected_gen)
                return
            end

            for _, spec in ipairs(dl_specs) do
                table.insert(tmp_paths, spec.dest .. "." .. tostring(pid) .. ".tmp")
            end
            _fetch_subproc = {
                pid = pid,
                read_fd = parent_read_fd,
                tmp_paths = tmp_paths,
                pending_jobs = pending_jobs,
                done_slot = done,
            }

            local attempts = 0
            local last_progress_attempt = 0
            local function pollSubProc()
                if expected_gen ~= _fetch_gen or not _fetch_subproc or _fetch_subproc.pid ~= pid then
                    return
                end
                attempts = attempts + 1
                local any_left = false
                for _, pj in ipairs(pending_jobs) do
                    if not pj.done then
                        if fileExists(pj.dest) then
                            pj.done = true
                            last_progress_attempt = attempts
                            if pj.cb then pcall(pj.cb, pj.dest) end
                        else
                            any_left = true
                        end
                    end
                end

                local stalled = (attempts - last_progress_attempt) > 120
                if ffiUtil.isSubProcessDone(pid) or not any_left or stalled then
                    cleanupSubProcess()
                    _fetch_poll_timer = nil
                    -- Final sweep for any file renamed right as the subprocess exited
                    for _, pj in ipairs(pending_jobs) do
                        if not pj.done and fileExists(pj.dest) then
                            pj.done = true
                            if pj.cb then pcall(pj.cb, pj.dest) end
                        end
                    end
                    return
                end

                _fetch_poll_timer = pollSubProc
                UIManager:scheduleIn(0.25, _fetch_poll_timer)
            end
            _fetch_poll_timer = pollSubProc
            UIManager:scheduleIn(0.25, _fetch_poll_timer)
        end,
    })
end

local function flushSettledQueue(expected_gen)
    _fetch_settle_timer = nil
    if expected_gen ~= _fetch_gen or #_fetch_queue == 0 then return end
    local batch = _fetch_queue
    _fetch_queue = {}

    table.sort(batch, function(a, b)
        return (a.priority or 1) < (b.priority or 1)
    end)

    if not canUseSubProcess() then
        _fetch_queue = batch
        pumpFallbackQueue(expected_gen)
        return
    end

    startSubProcessBatch(batch, expected_gen)
end

function Covers.enqueueFetchCover(entry, cb, open_doc, priority)
    if not entry then
        if cb then cb(nil) end
        return
    end
    local cached = Covers.getCachedCoverPath(entry)
    if cached then
        if cb then cb(cached) end
        return
    end
    if not entry.local_path and (not entry.has_cover or not entry.folder) then
        if cb then cb(nil) end
        return
    end
    table.insert(_fetch_queue, { entry = entry, cb = cb, open_doc = open_doc, priority = priority or 1 })
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local my_gen = _fetch_gen
    if ok_ui and UIManager and UIManager.scheduleIn then
        if not _fetch_settle_timer then
            _fetch_settle_timer = function() flushSettledQueue(my_gen) end
            UIManager:scheduleIn(0.35, _fetch_settle_timer)
        end
    else
        flushSettledQueue(my_gen)
    end
end

function Covers.computeFitSize(orig_w, orig_h, max_w, max_h)
    if not orig_w or not orig_h or orig_w <= 0 or orig_h <= 0 then
        return max_w, max_h
    end
    local scale = math.min(max_w / orig_w, max_h / orig_h)
    return math.max(1, math.floor(orig_w * scale + 0.5)), math.max(1, math.floor(orig_h * scale + 0.5))
end

local _scaled_bb_cache = {}
local _scaled_bb_order = {}
local _render_gen = 0
local MAX_BB_CACHE = 48

function Covers.beginRenderPass()
    _render_gen = _render_gen + 1
    return _render_gen
end

function Covers.pruneMemoryCache()
    local i = 1
    while #_scaled_bb_order > MAX_BB_CACHE and i <= #_scaled_bb_order do
        local key = _scaled_bb_order[i]
        local entry = _scaled_bb_cache[key]
        if not entry or (entry.gen or 0) < _render_gen then
            table.remove(_scaled_bb_order, i)
            _scaled_bb_cache[key] = nil
            if entry and entry.bb and entry.bb.free then
                pcall(function() entry.bb:free() end)
            end
        else
            i = i + 1
        end
    end
end

function Covers.invalidateMemoryCacheForPath(file_path)
    if not file_path or file_path == "" then return end
    local prefix = file_path .. ":"
    for idx = #_scaled_bb_order, 1, -1 do
        local k = _scaled_bb_order[idx]
        if k:sub(1, #prefix) == prefix then
            local entry = _scaled_bb_cache[k]
            local bb = type(entry) == "table" and entry.bb or entry
            if bb and bb.free then
                pcall(function() bb:free() end)
            end
            _scaled_bb_cache[k] = nil
            table.remove(_scaled_bb_order, idx)
        end
    end
end

function Covers.clearMemoryCache()
    for k, entry in pairs(_scaled_bb_cache) do
        local bb = type(entry) == "table" and entry.bb or entry
        if bb and bb.free then
            pcall(function() bb:free() end)
        end
        _scaled_bb_cache[k] = nil
    end
    _scaled_bb_order = {}
end

local function touchCacheOrder(key)
    for idx = #_scaled_bb_order, 1, -1 do
        if _scaled_bb_order[idx] == key then
            table.remove(_scaled_bb_order, idx)
            break
        end
    end
    table.insert(_scaled_bb_order, key)
end

local function getCachedScaledBB(key)
    local entry = _scaled_bb_cache[key]
    if not entry then return nil end
    entry.gen = _render_gen
    touchCacheOrder(key)
    return entry.bb
end

function Covers.hasMemoryCachedCover(file_path, target_w, target_h)
    if not file_path or not target_w or not target_h then return false end
    local cache_key = file_path .. ":" .. tostring(target_w) .. "x" .. tostring(target_h)
    return _scaled_bb_cache[cache_key] ~= nil
end

local function pumpDecodeQueue(expected_gen)
    _decode_timer = nil
    if expected_gen ~= _fetch_gen or #_decode_queue == 0 then
        _decode_queue = {}
        return
    end
    local item = table.remove(_decode_queue, 1)
    if item then
        local widget = Covers.createCoverImageWidget(item.file_path, item.target_w, item.target_h)
        if expected_gen == _fetch_gen and item.cb then
            pcall(item.cb, widget)
        end
    end
    if expected_gen == _fetch_gen and #_decode_queue > 0 then
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager and UIManager.scheduleIn then
            _decode_timer = function() pumpDecodeQueue(expected_gen) end
            UIManager:scheduleIn(0.01, _decode_timer)
        else
            pumpDecodeQueue(expected_gen)
        end
    end
end

function Covers.enqueueDecodeCover(file_path, target_w, target_h, cb)
    if not file_path or not target_w or not target_h then
        if cb then cb(nil) end
        return
    end
    if Covers.hasMemoryCachedCover(file_path, target_w, target_h) then
        local w = Covers.createCoverImageWidget(file_path, target_w, target_h)
        if cb then cb(w) end
        return
    end
    table.insert(_decode_queue, {
        file_path = file_path,
        target_w = target_w,
        target_h = target_h,
        cb = cb,
    })
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local my_gen = _fetch_gen
    if ok_ui and UIManager and UIManager.scheduleIn then
        if not _decode_timer then
            _decode_timer = function() pumpDecodeQueue(my_gen) end
            UIManager:scheduleIn(0.01, _decode_timer)
        end
    else
        pumpDecodeQueue(my_gen)
    end
end

local function putCachedScaledBB(key, bb)
    local existing = _scaled_bb_cache[key]
    if existing then
        existing.gen = _render_gen
        touchCacheOrder(key)
        return
    end
    _scaled_bb_cache[key] = { bb = bb, gen = _render_gen }
    table.insert(_scaled_bb_order, key)
end

function Covers.createCoverImageWidget(file_path, target_w, target_h)
    local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_iw or not ok_ri or not file_path or not target_w or not target_h then
        return nil
    end

    local cache_key = file_path .. ":" .. tostring(target_w) .. "x" .. tostring(target_h)
    local cached_bb = getCachedScaledBB(cache_key)
    if cached_bb then
        return ImageWidget:new{
            image = cached_bb,
            image_disposable = false,
            width = cached_bb:getWidth(),
            height = cached_bb:getHeight(),
        }
    end

    local ok, orig_bb = pcall(function()
        return RenderImage:renderImageFile(file_path, false)
    end)
    if not ok or not orig_bb then return nil end

    local orig_w = orig_bb:getWidth()
    local orig_h = orig_bb:getHeight()
    if not orig_w or not orig_h or orig_w <= 0 or orig_h <= 0 then
        if orig_bb.free then pcall(function() orig_bb:free() end) end
        return nil
    end

    local norm_bb, free_norm = normalizeToRGB24(orig_bb)
    if free_norm and orig_bb.free then
        pcall(function() orig_bb:free() end)
    end

    local fit_w, fit_h = Covers.computeFitSize(orig_w, orig_h, target_w, target_h)
    local ok_scale, scaled_bb = pcall(function()
        return RenderImage:scaleBlitBuffer(norm_bb, fit_w, fit_h, false)
    end)
    if norm_bb and norm_bb ~= scaled_bb and norm_bb.free then
        pcall(function() norm_bb:free() end)
    end
    if not ok_scale or not scaled_bb then return nil end

    putCachedScaledBB(cache_key, scaled_bb)
    return ImageWidget:new{
        image = scaled_bb,
        image_disposable = false,
        width = fit_w,
        height = fit_h,
    }
end

function Covers.createPlaceholderWidget(target_w, target_h, title)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")

    local label = TextBoxWidget:new{
        text = tostring(title or "Nimbus"),
        face = Font:getFace("cfont", 13),
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = math.max(20, target_w - 12),
        alignment = "center",
    }

    return FrameContainer:new{
        bordersize = 1,
        color = Blitbuffer.COLOR_DARK_GRAY,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        width = target_w,
        height = target_h,
        CenterContainer:new{
            dimen = Geom:new{ w = target_w, h = target_h },
            label,
        },
    }
end

function Covers.createFolderMosaicWidget(sample_books, slot_w, slot_h, on_async_loaded, open_doc, is_valid)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local Geom = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")
    local Widgets = require("nimbus_ui_widgets")

    local pad = 5
    local gap = 4
    local inner_w = math.max(20, slot_w - (pad * 2) - 2)
    local inner_h = math.max(20, slot_h - (pad * 2) - 2)
    local count = math.min(4, #(sample_books or {}))

    local function makeTileContainer(book, tile_w, tile_h, tile_idx)
        local cached = book and Covers.getCachedCoverPath(book)
        local tile_widget = cached and Covers.createCoverImageWidget(cached, tile_w, tile_h)
        if not tile_widget then
            tile_widget = FrameContainer:new{
                bordersize = 1,
                color = Blitbuffer.COLOR_GRAY_E,
                padding = 0,
                margin = 0,
                background = Blitbuffer.COLOR_WHITE,
                width = math.max(8, tile_w - 2),
                height = math.max(10, tile_h - 2),
                VerticalSpan:new{ width = 0 },
            }
        end
        local cell = CenterContainer:new{
            dimen = Geom:new{ w = tile_w, h = tile_h },
            tile_widget,
        }
        local function applyDecodedTile(new_img)
            if is_valid and not is_valid() then return end
            if new_img then
                cell[1] = new_img
                if on_async_loaded then
                    on_async_loaded()
                end
            end
        end
        if book and not cached then
            Covers.enqueueFetchCover(book, function(loaded_path)
                if is_valid and not is_valid() then return end
                if loaded_path then
                    Covers.enqueueDecodeCover(loaded_path, tile_w, tile_h, applyDecodedTile)
                end
            end, open_doc, tile_idx or 1)
        end
        return cell
    end

    local content
    if count == 0 then
        local icon_sz = math.max(24, math.floor(math.min(inner_w, inner_h) * 0.42))
        content = ImageWidget:new{
            file = Widgets.getAssetPath("folder.svg"),
            width = icon_sz,
            height = icon_sz,
            scale_factor = 0,
            is_icon = true,
            alpha = true,
        }
    elseif count == 1 then
        content = makeTileContainer(sample_books[1], inner_w, inner_h, 1)
    elseif count == 2 then
        local mini_w = math.max(8, math.floor((inner_w - gap) / 2))
        content = HorizontalGroup:new{
            align = "center",
            makeTileContainer(sample_books[1], mini_w, inner_h, 1),
            HorizontalSpan:new{ width = gap },
            makeTileContainer(sample_books[2], mini_w, inner_h, 2),
        }
    elseif count == 3 then
        local mini_w = math.max(8, math.floor((inner_w - gap) / 2))
        local mini_h = math.max(10, math.floor((inner_h - gap) / 2))
        local row1 = HorizontalGroup:new{
            align = "center",
            makeTileContainer(sample_books[1], mini_w, mini_h, 1),
            HorizontalSpan:new{ width = gap },
            makeTileContainer(sample_books[2], mini_w, mini_h, 2),
        }
        local row2 = makeTileContainer(sample_books[3], mini_w, mini_h, 3)
        content = VerticalGroup:new{
            align = "center",
            row1,
            VerticalSpan:new{ width = gap },
            row2,
        }
    else
        local mini_w = math.max(8, math.floor((inner_w - gap) / 2))
        local mini_h = math.max(10, math.floor((inner_h - gap) / 2))
        local row1 = HorizontalGroup:new{
            align = "center",
            makeTileContainer(sample_books[1], mini_w, mini_h, 1),
            HorizontalSpan:new{ width = gap },
            makeTileContainer(sample_books[2], mini_w, mini_h, 2),
        }
        local row2 = HorizontalGroup:new{
            align = "center",
            makeTileContainer(sample_books[3], mini_w, mini_h, 3),
            HorizontalSpan:new{ width = gap },
            makeTileContainer(sample_books[4], mini_w, mini_h, 4),
        }
        content = VerticalGroup:new{
            align = "center",
            row1,
            VerticalSpan:new{ width = gap },
            row2,
        }
    end

    return FrameContainer:new{
        bordersize = 1,
        color = Blitbuffer.COLOR_DARK_GRAY,
        radius = 4,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            content,
        },
    }
end

return Covers
