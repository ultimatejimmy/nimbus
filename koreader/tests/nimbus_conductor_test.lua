local NimbusConductor = require("nimbus_conductor")
local Sync = require("nimbus_sync")
local Cloud = require("nimbus_cloud")
local Covers = require("nimbus_covers")
local Scanner = require("nimbus_scanner")

describe("nimbus_conductor & upgraded Conductor API integration", function()
    local orig_conductor
    local orig_ui
    local orig_fu
    local orig_dev

    before_each(function()
        orig_conductor = package.loaded["storefront_conductor"]
        orig_ui = package.loaded["ui/uimanager"]
        orig_fu = package.loaded["ffi/util"]
        orig_dev = package.loaded["device"]
        Sync._active_bg_jobs = {}
        Sync._bg_cancel = nil
        Sync._bg_pid = nil
        Sync._bg_running = false
        Sync._bg_slot_pending = false
        Sync._last_bg_sync_ts = nil
    end)

    after_each(function()
        package.loaded["storefront_conductor"] = orig_conductor
        package.loaded["ui/uimanager"] = orig_ui
        package.loaded["ffi/util"] = orig_fu
        package.loaded["device"] = orig_dev
        Sync._active_bg_jobs = {}
        Sync._bg_cancel = nil
    end)

    it("lazily registers plugin profile even when storefront_conductor loads later", function()
        package.loaded["storefront_conductor"] = nil
        local registered_profile = nil
        local calls = 0

        NimbusConductor.setProfile({
            plugin = "nimbus",
            is_foreground = function() return false end,
            on_reclaim = function() end,
            on_cancel_bg = function() end,
        })
        assert.is_false(NimbusConductor.ensureRegistered())

        -- Simulate storefront.koplugin loading later
        package.loaded["storefront_conductor"] = {
            registerPlugin = function(p)
                calls = calls + 1
                registered_profile = p
            end,
            requestSlot = function(opts)
                opts.run(function() end)
            end,
        }

        assert.is_true(NimbusConductor.ensureRegistered())
        assert.is_not_nil(registered_profile)
        assert.are.equal("nimbus", registered_profile.plugin)
        assert.are.equal(1, calls)

        -- Subsequent calls against the same module do not re-register
        assert.is_true(NimbusConductor.ensureRegistered())
        assert.are.equal(1, calls)
    end)

    it("falls back to direct execution when storefront_conductor is absent", function()
        package.loaded["storefront_conductor"] = nil
        local ran = false
        NimbusConductor.requestSlot({
            plugin = "nimbus",
            task = "fallback_test",
            run = function(done)
                ran = true
                done()
            end,
        })
        assert.is_true(ran)
    end)

    it("routes user_initiated Sync.runInBackground through Conductor at foreground priority", function()
        local timers = {}
        local captured_opts = nil
        local done_calls = 0

        package.loaded["device"] = { isAndroid = function() return true end }
        package.loaded["ui/uimanager"] = {
            scheduleIn = function(_, _, fn) table.insert(timers, fn) end,
            unschedule = function() end,
        }
        package.loaded["storefront_conductor"] = {
            registerPlugin = function() end,
            requestSlot = function(opts)
                captured_opts = opts
                opts.run(function()
                    done_calls = done_calls + 1
                end)
            end,
        }

        local final_ok, final_res
        Sync.runInBackground(function()
            return { ok = true }
        end, function(ok, res)
            final_ok = ok
            final_res = res
        end, {
            user_initiated = true,
            task = "download_book",
            lease_s = 90,
            dedupe_key = "nimbus:dl:123",
            min_free_kb = 32768,
        })

        assert.is_not_nil(captured_opts)
        assert.are.equal("nimbus", captured_opts.plugin)
        assert.are.equal("foreground", captured_opts.priority)
        assert.are.equal("download_book", captured_opts.task)
        assert.are.equal(90, captured_opts.lease_s)
        assert.are.equal("nimbus:dl:123", captured_opts.dedupe_key)
        assert.are.equal(32768, captured_opts.min_free_kb)
        assert.is_false(captured_opts.subprocess)
        assert.are.equal(0, done_calls)

        assert.are.equal(1, #timers)
        timers[1]()
        assert.is_true(final_ok)
        assert.is_true(final_res.ok)
        assert.are.equal(1, done_calls)
    end)

    it("propagates Conductor on_rejected to on_complete and opts.on_rejected", function()
        package.loaded["device"] = { isAndroid = function() return true end }
        package.loaded["ui/uimanager"] = {
            scheduleIn = function() end,
            unschedule = function() end,
        }
        package.loaded["storefront_conductor"] = {
            registerPlugin = function() end,
            requestSlot = function(opts)
                opts.on_rejected("low_memory")
            end,
        }

        local rejected_reason = nil
        local cb_ok, cb_res
        Sync.runInBackground(function()
            return { ok = true }
        end, function(ok, res)
            cb_ok = ok
            cb_res = res
        end, {
            priority = "idle_bg",
            task = "sync_current_book",
            on_rejected = function(r) rejected_reason = r end,
        })

        assert.are.equal("low_memory", rejected_reason)
        assert.is_false(cb_ok)
        assert.are.equal("low_memory", cb_res)
    end)

    it("cancels idle background tasks via Sync.cancelBackgroundTasks without canceling foreground jobs", function()
        local timers = {}
        local canceled_tasks = {}

        package.loaded["device"] = { isAndroid = function() return true end }
        package.loaded["ui/uimanager"] = {
            scheduleIn = function(_, _, fn) table.insert(timers, fn) end,
            unschedule = function() end,
        }
        package.loaded["storefront_conductor"] = {
            registerPlugin = function() end,
            requestSlot = function(opts)
                opts.run(function() end)
            end,
        }

        local bg_ok, bg_res
        Sync.runInBackground(function() return "bg" end, function(ok, res)
            bg_ok = ok
            bg_res = res
        end, { task = "bg_job" })

        local fg_done = false
        Sync.runInBackground(function() return "fg" end, function(ok, res)
            fg_done = (ok == true and res == "fg")
        end, { user_initiated = true, task = "fg_job" })

        Sync.cancelBackgroundTasks()

        assert.is_false(bg_ok)
        assert.are.equal("canceled", bg_res)
        assert.is_false(fg_done)

        -- Firing timers: bg_job is a no-op, fg_job completes normally
        for _, t in ipairs(timers) do t() end
        assert.is_true(fg_done)
    end)

    it("requests and releases a Conductor slot for startBackgroundCatalogSync and resets throttle on rejection", function()
        local orig_cfg = Cloud.isConfigured
        Cloud.isConfigured = function() return true end
        package.loaded["device"] = { isAndroid = function() return true end }
        package.loaded["ui/uimanager"] = {
            scheduleIn = function() end,
            unschedule = function() end,
        }

        local captured_opts = nil
        package.loaded["storefront_conductor"] = {
            registerPlugin = function() end,
            requestSlot = function(opts)
                captured_opts = opts
                opts.on_rejected("suspended")
            end,
        }

        local cb_ok, cb_err
        local started = Sync.startBackgroundCatalogSync(function(ok, err)
            cb_ok = ok
            cb_err = err
        end, false)

        Cloud.isConfigured = orig_cfg
        assert.is_true(started)
        assert.is_not_nil(captured_opts)
        assert.are.equal("catalog_sync", captured_opts.task)
        assert.are.equal("idle_bg", captured_opts.priority)
        assert.are.equal("nimbus:catalog_sync", captured_opts.dedupe_key)
        assert.is_false(cb_ok)
        assert.are.equal("suspended", cb_err)
        assert.are.equal(0, Sync._last_bg_sync_ts)
    end)

    it("requests and releases a Conductor slot for Covers subprocess batch", function()
        local timers = {}
        local child_done = false
        local captured_opts = nil
        local slot_done_calls = 0

        package.loaded["device"] = { isAndroid = function() return false end }
        package.loaded["ui/uimanager"] = {
            scheduleIn = function(_, _, fn) table.insert(timers, fn) end,
            unschedule = function() end,
        }
        package.loaded["ffi/util"] = {
            runInSubProcess = function()
                return 8888, 77
            end,
            terminateSubProcess = function() end,
            isSubProcessDone = function() return child_done end,
            readAllFromFD = function() return "DONE" end,
        }
        package.loaded["storefront_conductor"] = {
            registerPlugin = function() end,
            requestSlot = function(opts)
                captured_opts = opts
                opts.run(function()
                    slot_done_calls = slot_done_calls + 1
                end)
            end,
        }

        Covers.enqueueFetchCover({ id = "cov_cond_1", local_path = "/tmp/c1.epub" }, function() end)
        assert.is_true(#timers >= 1)
        timers[1]() -- flushSettledQueue -> startSubProcessBatch

        assert.is_not_nil(captured_opts)
        assert.are.equal("fetch_covers", captured_opts.task)
        assert.are.equal("interactive_bg", captured_opts.priority)
        assert.is_true(captured_opts.subprocess)
        assert.are.equal(0, slot_done_calls)

        child_done = true
        timers[#timers]() -- pollSubProc sees done -> cleanupSubProcess -> releases slot
        assert.are.equal(1, slot_done_calls)
    end)

    it("reclaimCaches sheds Scanner._mem_cache on soft reclaim when in background, preserves in foreground", function()
        local orig_wc = package.loaded["ui/widget/container/widgetcontainer"]
        local orig_disp = package.loaded["dispatcher"]
        local orig_ev = package.loaded["ui/event"]
        local orig_uilib = package.loaded["nimbus_ui_library"]
        local orig_widgets = package.loaded["nimbus_ui_widgets"]
        local orig_prog = package.loaded["nimbus_progress"]
        local orig_main = package.loaded["main"]
        local orig_ui_mgr = package.loaded["ui/uimanager"]

        local is_fg = true
        package.loaded["ui/widget/container/widgetcontainer"] = {
            extend = function(_, t) return t end,
        }
        package.loaded["ui/uimanager"] = {
            scheduleIn = function() end,
            nextTick = function() end,
        }
        package.loaded["dispatcher"] = { registerAction = function() end }
        package.loaded["ui/event"] = { new = function(_, ...) return {} end }
        package.loaded["nimbus_ui_library"] = {
            isOpen = function() return is_fg end,
        }
        package.loaded["nimbus_ui_widgets"] = {}
        package.loaded["nimbus_progress"] = {}
        package.loaded["main"] = nil

        local Nimbus = require("main")

        Scanner._mem_cache = { { title = "Cached Book" } }
        is_fg = true
        Nimbus:onMemoryReclaim("soft")
        assert.is_not_nil(Scanner._mem_cache)

        is_fg = false
        Nimbus:onMemoryReclaim("soft")
        assert.is_nil(Scanner._mem_cache)

        Scanner._mem_cache = { { title = "Cached Book" } }
        is_fg = true
        Nimbus:onMemoryReclaim("critical")
        assert.is_nil(Scanner._mem_cache)

        package.loaded["ui/widget/container/widgetcontainer"] = orig_wc
        package.loaded["dispatcher"] = orig_disp
        package.loaded["ui/event"] = orig_ev
        package.loaded["nimbus_ui_library"] = orig_uilib
        package.loaded["nimbus_ui_widgets"] = orig_widgets
        package.loaded["nimbus_progress"] = orig_prog
        package.loaded["main"] = orig_main
        package.loaded["ui/uimanager"] = orig_ui_mgr
    end)
end)
