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
local Hash = require("nimbus_hash")

local Covers = {}

local function fileExists(path)
    if not path then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
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

function Covers.getCoverFilePath(entry)
    local key = makeCacheKey(entry)
    if not key then return nil end
    local dir = Settings.getCoversCacheDir()
    if ok_util and util and util.makePath then
        util.makePath(dir)
    elseif lfs and lfs.mkdir then
        lfs.mkdir(Settings.getCacheDir())
        lfs.mkdir(dir)
    end
    return dir .. "/" .. key .. ".jpg"
end

function Covers.getCachedCoverPath(entry)
    local path = Covers.getCoverFilePath(entry)
    if path and fileExists(path) then
        return path
    end
    return nil
end

local function writeScaledBlitBuffer(orig_bb, dest_path)
    if not orig_bb or not dest_path then return false end
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    local orig_w = orig_bb.getWidth and orig_bb:getWidth()
    local orig_h = orig_bb.getHeight and orig_bb:getHeight()
    if not orig_w or not orig_h or orig_w <= 0 or orig_h <= 0 then
        return false
    end

    local target_bb = orig_bb
    local scaled_bb = nil
    if ok_ri and RenderImage and orig_w > 400 then
        local new_w = 400
        local new_h = math.max(1, math.floor(orig_h * (400 / orig_w)))
        local ok_s, res_bb = pcall(function()
            return RenderImage:scaleBlitBuffer(orig_bb, new_w, new_h, false)
        end)
        if ok_s and res_bb then
            scaled_bb = res_bb
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

    if scaled_bb and scaled_bb.free then
        pcall(function() scaled_bb:free() end)
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
function Covers.extractLocalCoverToFile(filepath, dest_path, open_doc)
    if not filepath or not dest_path or not fileExists(filepath) then
        return false
    end
    if fileExists(dest_path) then
        return true
    end

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
    if open_doc and open_doc.file == filepath and open_doc.getCoverPageImage then
        local ok_bb, bb = pcall(function() return open_doc:getCoverPageImage() end)
        if ok_bb and bb then
            local ok_w = writeScaledBlitBuffer(bb, dest_path)
            if bb.free then pcall(function() bb:free() end) end
            if ok_w then return true end
        end
    end

    -- 3. Check KOReader's BookInfoManager cache if available
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if ok_bim and BookInfoManager and BookInfoManager.getBookInfo then
        local ok_bi, info = pcall(function() return BookInfoManager:getBookInfo(filepath, true) end)
        if ok_bi and type(info) == "table" and info.cover_bb then
            local ok_w = writeScaledBlitBuffer(info.cover_bb, dest_path)
            if info.cover_bb.free then pcall(function() info.cover_bb:free() end) end
            if ok_w then return true end
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

    if entry.local_path and Covers.extractLocalCoverToFile(entry.local_path, dest, open_doc) then
        if cb then cb(dest) end
        return dest
    end

    if not entry.has_cover or not entry.folder then
        if cb then cb(nil) end
        return nil
    end

    local tmp = dest .. ".tmp"
    Cloud.downloadFile(entry.folder .. "/cover.jpg", tmp, function(ok)
        if ok then
            os.remove(dest)
            if os.rename(tmp, dest) then
                if cb then cb(dest) end
                return
            end
        end
        os.remove(tmp)
        if cb then cb(nil) end
    end)
end

local _fetch_queue = {}
local _fetch_running = false

function Covers.clearFetchQueue()
    _fetch_queue = {}
end

local function pumpFetchQueue()
    if _fetch_running then return end
    local job = table.remove(_fetch_queue, 1)
    if not job then return end
    _fetch_running = true
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    Covers.fetchCover(job.entry, function(path)
        _fetch_running = false
        if job.cb then pcall(job.cb, path) end
        if ok_ui and UIManager and UIManager.nextTick then
            UIManager:nextTick(pumpFetchQueue)
        else
            pumpFetchQueue()
        end
    end, job.open_doc)
end

function Covers.enqueueFetchCover(entry, cb, open_doc)
    if not entry then
        if cb then cb(nil) end
        return
    end
    local cached = Covers.getCachedCoverPath(entry)
    if cached then
        if cb then cb(cached) end
        return
    end
    table.insert(_fetch_queue, { entry = entry, cb = cb, open_doc = open_doc })
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and UIManager and UIManager.nextTick then
        UIManager:nextTick(pumpFetchQueue)
    else
        pumpFetchQueue()
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
local MAX_BB_CACHE = 12

function Covers.clearMemoryCache()
    for k, bb in pairs(_scaled_bb_cache) do
        if bb and bb.free then
            pcall(function() bb:free() end)
        end
        _scaled_bb_cache[k] = nil
    end
    _scaled_bb_order = {}
end

local function getCachedScaledBB(key)
    return _scaled_bb_cache[key]
end

local function putCachedScaledBB(key, bb)
    if _scaled_bb_cache[key] then return end
    if #_scaled_bb_order >= MAX_BB_CACHE then
        local evict = table.remove(_scaled_bb_order, 1)
        local old_bb = _scaled_bb_cache[evict]
        _scaled_bb_cache[evict] = nil
        if old_bb and old_bb.free then
            pcall(function() old_bb:free() end)
        end
    end
    _scaled_bb_cache[key] = bb
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

    local fit_w, fit_h = Covers.computeFitSize(orig_w, orig_h, target_w, target_h)
    local ok_scale, scaled_bb = pcall(function()
        return RenderImage:scaleBlitBuffer(orig_bb, fit_w, fit_h, false)
    end)
    if orig_bb.free then pcall(function() orig_bb:free() end) end
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

function Covers.createFolderMosaicWidget(sample_books, slot_w, slot_h, on_async_loaded, open_doc)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local LineWidget = require("ui/widget/linewidget")
    local Geom = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")
    local UIManager = require("ui/uimanager")

    local pad = 5
    local gap = 4
    local inner_w = math.max(20, slot_w - (pad * 2) - 2)
    local inner_h = math.max(20, slot_h - (pad * 2) - 2)
    local mini_w = math.max(8, math.floor((inner_w - gap) / 2))
    local mini_h = math.max(10, math.floor((inner_h - gap) / 2))

    local function makeEmptyTile()
        return LineWidget:new{
            dimen = Geom:new{ w = mini_w, h = mini_h },
            background = Blitbuffer.COLOR_GRAY_E,
        }
    end

    local cells = {}
    for idx = 1, 4 do
        local b = sample_books and sample_books[idx]
        local cell_widget
        if b then
            local cached = Covers.getCachedCoverPath(b)
            cell_widget = cached and Covers.createCoverImageWidget(cached, mini_w, mini_h)
            if not cell_widget then
                cell_widget = makeEmptyTile()
                Covers.enqueueFetchCover(b, function(loaded_path)
                    if loaded_path and on_async_loaded then
                        on_async_loaded()
                    end
                end, open_doc)
            end
        else
            cell_widget = makeEmptyTile()
        end
        cells[idx] = CenterContainer:new{
            dimen = Geom:new{ w = mini_w, h = mini_h },
            cell_widget,
        }
    end

    local row1 = HorizontalGroup:new{ align = "center", cells[1], HorizontalSpan:new{ width = gap }, cells[2] }
    local row2 = HorizontalGroup:new{ align = "center", cells[3], HorizontalSpan:new{ width = gap }, cells[4] }
    local grid = VerticalGroup:new{ align = "center", row1, VerticalSpan:new{ width = gap }, row2 }

    return FrameContainer:new{
        bordersize = 1,
        color = Blitbuffer.COLOR_DARK_GRAY,
        radius = 4,
        padding = pad,
        margin = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            grid,
        },
    }
end

return Covers
