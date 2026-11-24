local Covers = require("nimbus_covers")
local Settings = require("nimbus_settings")

describe("nimbus_covers cache safety & normalization", function()
    local orig_iw, orig_ri, orig_bb

    before_each(function()
        orig_iw = package.loaded["ui/widget/imagewidget"]
        orig_ri = package.loaded["ui/renderimage"]
        orig_bb = package.loaded["ffi/blitbuffer"]
        Covers.clearMemoryCache()
    end)

    after_each(function()
        package.loaded["ui/widget/imagewidget"] = orig_iw
        package.loaded["ui/renderimage"] = orig_ri
        package.loaded["ffi/blitbuffer"] = orig_bb
        Covers.clearMemoryCache()
    end)

    it("never frees BlitBuffers allocated during the active render pass", function()
        local freed = {}
        local next_id = 0
        local function makeBB(w, h, bb_type, stride)
            next_id = next_id + 1
            local id = next_id
            return {
                id = id,
                stride = stride or (w * 3),
                getWidth = function() return w end,
                getHeight = function() return h end,
                getType = function() return bb_type or 1 end,
                free = function() freed[id] = true end,
            }
        end

        package.loaded["ffi/blitbuffer"] = {
            TYPE_BBRGB24 = 1,
            TYPE_BBRGB32 = 2,
            TYPE_BB8A = 3,
            COLOR_WHITE = 0,
            new = function(w, h, t) return makeBB(w, h, t) end,
        }
        package.loaded["ui/widget/imagewidget"] = {
            new = function(_, o) return o end,
        }
        package.loaded["ui/renderimage"] = {
            renderImageFile = function(_, path)
                return makeBB(200, 300, 1)
            end,
            scaleBlitBuffer = function(_, bb, w, h)
                return makeBB(w, h, 1)
            end,
        }

        Covers.beginRenderPass()
        local active_widgets = {}
        for i = 1, 55 do
            local w = Covers.createCoverImageWidget("tests/tmp/fake_" .. i .. ".jpg", 100, 150)
            assert.is_not_nil(w)
            table.insert(active_widgets, w)
        end

        -- Nothing from the active pass should have been freed
        for _, w in ipairs(active_widgets) do
            assert.is_nil(freed[w.image.id])
        end

        -- Even calling pruneMemoryCache right after the pass keeps active_pass entries
        Covers.pruneMemoryCache()
        for _, w in ipairs(active_widgets) do
            assert.is_nil(freed[w.image.id])
        end

        -- Next render pass with 50 new covers allows old generation entries beyond MAX_BB_CACHE (48) to be freed
        Covers.beginRenderPass()
        for i = 100, 149 do
            Covers.createCoverImageWidget("tests/tmp/fake_" .. i .. ".jpg", 100, 150)
        end
        Covers.pruneMemoryCache()
        local freed_count = 0
        for _ in pairs(freed) do freed_count = freed_count + 1 end
        assert.is_true(freed_count > 0)
    end)

    it("normalizes non-RGB24 or padded-pitch BlitBuffers via alphablitFrom onto white", function()
        local filled_white = false
        local alpha_blitted = false
        local Blitbuffer = {
            TYPE_BBRGB24 = 1,
            TYPE_BBRGB32 = 2,
            TYPE_BB8A = 3,
            COLOR_WHITE = 0xFFFFFF,
            new = function(w, h, t)
                return {
                    pitch = w * 3,
                    getWidth = function() return w end,
                    getHeight = function() return h end,
                    getType = function() return t end,
                    fill = function(_, c) if c == 0xFFFFFF then filled_white = true end end,
                    alphablitFrom = function() alpha_blitted = true end,
                    blitFrom = function() end,
                    free = function() end,
                }
            end,
        }
        package.loaded["ffi/blitbuffer"] = Blitbuffer

        local src_rgba = {
            stride = 400,
            getWidth = function() return 100 end,
            getHeight = function() return 150 end,
            getType = function() return Blitbuffer.TYPE_BBRGB32 end,
        }
        local norm, should_free = Covers._normalizeToRGB24(src_rgba)
        assert.is_true(should_free)
        assert.is_true(filled_white)
        assert.is_true(alpha_blitted)
        assert.are.equal(Blitbuffer.TYPE_BBRGB24, norm:getType())
    end)

    it("does not free scaled_bb when RenderImage:scaleBlitBuffer returns norm_bb unchanged", function()
        local freed_bb = false
        local same_bb = {
            stride = 100 * 3,
            getWidth = function() return 100 end,
            getHeight = function() return 150 end,
            getType = function() return 1 end,
            free = function() freed_bb = true end,
        }
        package.loaded["ffi/blitbuffer"] = {
            TYPE_BBRGB24 = 1,
            TYPE_BBRGB32 = 2,
            TYPE_BB8A = 3,
            COLOR_WHITE = 0,
        }
        package.loaded["ui/widget/imagewidget"] = {
            new = function(_, o) return o end,
        }
        package.loaded["ui/renderimage"] = {
            renderImageFile = function() return same_bb end,
            scaleBlitBuffer = function(_, bb) return bb end,
        }
        Covers.beginRenderPass()
        local w = Covers.createCoverImageWidget("tests/tmp/exact_size.jpg", 100, 150)
        assert.is_not_nil(w)
        assert.is_false(freed_bb)
    end)

    it("normalizes real KOReader FFI BlitBuffer cdata without struct field errors", function()
        package.loaded["ffi/blitbuffer"] = nil
        local ok_bb, RealBB = pcall(require, "ffi/blitbuffer")
        if not ok_bb or not RealBB or not RealBB.new then
            return
        end
        local bb24 = RealBB.new(32, 48, RealBB.TYPE_BBRGB24)
        local n24, f24 = Covers._normalizeToRGB24(bb24)
        assert.is_false(f24)
        assert.are.equal(bb24, n24)
        bb24:free()

        local bb32 = RealBB.new(32, 48, RealBB.TYPE_BBRGB32)
        local n32, f32 = Covers._normalizeToRGB24(bb32)
        assert.is_true(f32)
        assert.are.equal(RealBB.TYPE_BBRGB24, n32:getType())
        n32:free()
        bb32:free()
    end)

    it("creates .cache_v2 and .reupload_pending once when migrating cover cache", function()
        local covers_dir = Settings.getCoversCacheDir()
        os.remove(covers_dir .. "/.cache_v2")
        os.remove(covers_dir .. "/.reupload_pending")
        -- Reset internal flag by reloading module
        package.loaded["nimbus_covers"] = nil
        local FreshCovers = require("nimbus_covers")
        local p = FreshCovers.getCoverFilePath({ id = "test_book_v2" })
        assert.is_not_nil(p)
        assert.is_true(FreshCovers.hasPendingCloudCoverReupload())
        FreshCovers.clearPendingCloudCoverReupload()
        assert.is_false(FreshCovers.hasPendingCloudCoverReupload())
    end)

    it("uses _v2 cache path and removes stale pre-v2 file when cover_etag starts with v2_", function()
        local entry = { id = "etag_book_1" }
        local old_path = Covers.getCoverFilePath(entry)
        local f = io.open(old_path, "wb")
        assert.is_not_nil(f)
        f:write("stale-grayscale")
        f:close()

        entry.cover_etag = "v2_1700000000"
        local v2_path = Covers.getCoverFilePath(entry)
        assert.is_not_nil(v2_path:find("_v2%.jpg$"))
        -- Old pre-v2 cache file should have been removed
        local check_old = io.open(old_path, "rb")
        assert.is_nil(check_old)
    end)

    it("cancels debounced queue cleanly via clearFetchQueue without crashing", function()
        local orig_ui = package.loaded["ui/uimanager"]
        local scheduled = nil
        local unscheduled = nil
        package.loaded["ui/uimanager"] = {
            scheduleIn = function(_, _, fn) scheduled = fn end,
            unschedule = function(_, fn) unscheduled = fn end,
        }
        local called = false
        Covers.enqueueFetchCover({ id = "queued_1", has_cover = true, folder = "Books/A" }, function()
            called = true
        end)
        assert.is_not_nil(scheduled)
        Covers.clearFetchQueue()
        assert.are.equal(scheduled, unscheduled)
        -- Firing stale timer after clearFetchQueue must be a no-op
        scheduled()
        assert.is_false(called)
        package.loaded["ui/uimanager"] = orig_ui
    end)

    it("never calls blocking waitpid (isSubProcessDone(pid, true)) during clearFetchQueue", function()
        local orig_ui = package.loaded["ui/uimanager"]
        local orig_fu = package.loaded["ffi/util"]
        local orig_dev = package.loaded["device"]
        local timers = {}
        local wait_flags = {}
        local terminated = false
        local spawned_count = 0

        package.loaded["device"] = { isAndroid = function() return false end }
        package.loaded["ui/uimanager"] = {
            scheduleIn = function(_, _, fn) table.insert(timers, fn) end,
            unschedule = function() end,
        }
        package.loaded["ffi/util"] = {
            runInSubProcess = function(fn, _double_fork)
                spawned_count = spawned_count + 1
                return 4242, 99
            end,
            terminateSubProcess = function() terminated = true end,
            isSubProcessDone = function(_, wait)
                table.insert(wait_flags, wait == true)
                return false
            end,
            readAllFromFD = function() return "" end,
        }

        Covers.enqueueFetchCover({ id = "local_1", local_path = "/tmp/book1.epub" }, function() end)
        -- Fire settle timer to spawn subprocess
        assert.is_true(#timers >= 1)
        timers[1]()
        assert.are.equal(1, spawned_count)

        Covers.clearFetchQueue()
        assert.is_true(terminated)
        for _, w in ipairs(wait_flags) do
            assert.is_false(w)
        end

        package.loaded["ui/uimanager"] = orig_ui
        package.loaded["ffi/util"] = orig_fu
        package.loaded["device"] = orig_dev
    end)

    it("decodes disk-cached covers incrementally via enqueueDecodeCover and aborts on clearFetchQueue", function()
        local orig_ui = package.loaded["ui/uimanager"]
        local orig_iw = package.loaded["ui/widget/imagewidget"]
        local orig_ri = package.loaded["ui/renderimage"]
        local orig_bb = package.loaded["ffi/blitbuffer"]
        local timers = {}

        package.loaded["ui/uimanager"] = {
            scheduleIn = function(_, _, fn) table.insert(timers, fn) end,
            unschedule = function() end,
        }
        package.loaded["ffi/blitbuffer"] = {
            TYPE_BBRGB24 = 1, TYPE_BBRGB32 = 2, TYPE_BB8A = 3, COLOR_WHITE = 0,
        }
        package.loaded["ui/widget/imagewidget"] = {
            new = function(_, o) return o end,
        }
        package.loaded["ui/renderimage"] = {
            renderImageFile = function()
                return {
                    stride = 300,
                    getWidth = function() return 100 end,
                    getHeight = function() return 150 end,
                    getType = function() return 1 end,
                }
            end,
            scaleBlitBuffer = function(_, bb) return bb end,
        }

        local decoded = {}
        assert.is_false(Covers.hasMemoryCachedCover("tests/tmp/dec_1.jpg", 100, 150))
        Covers.enqueueDecodeCover("tests/tmp/dec_1.jpg", 100, 150, function(w) table.insert(decoded, w) end)
        Covers.enqueueDecodeCover("tests/tmp/dec_2.jpg", 100, 150, function(w) table.insert(decoded, w) end)
        assert.are.equal(0, #decoded)

        -- First tick decodes only 1 cover
        timers[1]()
        assert.are.equal(1, #decoded)
        assert.is_true(Covers.hasMemoryCachedCover("tests/tmp/dec_1.jpg", 100, 150))

        -- Clear queue before second tick
        Covers.clearFetchQueue()
        timers[2]()
        assert.are.equal(1, #decoded)

        package.loaded["ui/uimanager"] = orig_ui
        package.loaded["ui/widget/imagewidget"] = orig_iw
        package.loaded["ui/renderimage"] = orig_ri
        package.loaded["ffi/blitbuffer"] = orig_bb
    end)

    it("invalidates stale disk cache on v2_cal_ cover_etag change and prefers cloud cover over local file", function()
        local Cloud = require("nimbus_cloud")
        local orig_dl = Cloud.downloadFile
        local orig_extract = Covers.extractLocalCoverToFile

        local entry = {
            id = "cal_etag_book",
            folder = "Books/CalibreBook",
            has_cover = true,
            local_path = "tests/tmp/cal_local.epub",
            cover_etag = "v2_cal_aaa111",
        }
        local path = Covers.getCoverFilePath(entry)
        local f = io.open(path, "wb")
        assert.is_not_nil(f)
        f:write("old-cover")
        f:close()
        Covers.writeEtag(path, "v2_cal_aaa111")

        -- Matching etag returns cached path
        assert.are.equal(path, Covers.getCachedCoverPath(entry))

        -- Updated Calibre etag invalidates stale cache and returns nil
        entry.cover_etag = "v2_cal_bbb222"
        assert.is_nil(Covers.getCachedCoverPath(entry))
        local check_gone = io.open(path, "rb")
        assert.is_nil(check_gone)

        -- fetchCover downloads from cloud before local extraction when cover_etag is v2_cal_
        local extract_called = false
        local downloaded_rel = nil
        Covers.extractLocalCoverToFile = function()
            extract_called = true
            return true
        end
        Cloud.downloadFile = function(rel, dest, cb)
            downloaded_rel = rel
            local out = io.open(dest, "wb")
            if out then out:write("new-calibre-cover"); out:close() end
            if cb then cb(true) end
        end

        local fetched_path = nil
        Covers.fetchCover(entry, function(p) fetched_path = p end)

        Cloud.downloadFile = orig_dl
        Covers.extractLocalCoverToFile = orig_extract

        assert.is_false(extract_called)
        assert.are.equal("Books/CalibreBook/cover.jpg", downloaded_rel)
        assert.are.equal(path, fetched_path)
        assert.are.equal(path, Covers.getCachedCoverPath(entry))

        -- pruneStaleCovers sweeps stale entries across catalog
        entry.cover_etag = "v2_cal_ccc333"
        local pruned = Covers.pruneStaleCovers({ [entry.id] = entry })
        assert.are.equal(1, pruned)
        assert.is_nil(Covers.getCachedCoverPath(entry))
    end)
end)
