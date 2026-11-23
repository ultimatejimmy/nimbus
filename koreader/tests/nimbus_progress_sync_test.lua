local Sync = require("nimbus_sync")
local Cloud = require("nimbus_cloud")
local Settings = require("nimbus_settings")

describe("nimbus_sync Android guard & progress collection", function()
    local orig_device

    before_each(function()
        orig_device = package.loaded["device"]
    end)

    after_each(function()
        package.loaded["device"] = orig_device
    end)

    it("disables runInSubProcess on Android to prevent Bionic FORTIFY crashes", function()
        package.loaded["device"] = {
            isAndroid = function() return true end,
        }
        assert.is_false(Sync.canUseSubProcess())
    end)

    it("collectAndUploadLocalProgress pushes .sdr progress to local_state and merged_progress", function()
        local uploaded_payload = nil
        local orig_upload = Cloud.uploadString
        local orig_cfg = Cloud.isConfigured
        Cloud.isConfigured = function() return true end
        Cloud.uploadString = function(rel, body, mime, cb)
            if rel:find("progress.json", 1, true) then
                uploaded_payload = body
            end
            if cb then cb(true) end
        end

        Sync.saveLocalState({ progress = {}, annotations = {} })

        local catalog = {
            books = {
                b1 = { id = "b1", title = "Book One", deleted = false },
                b2 = { id = "b2", title = "Book Two", deleted = false },
            },
        }
        local device_books = {
            {
                cloud_id = "b1",
                percent = 0.64,
                status = "reading",
                last_read_ts = 1700000100,
                partial_md5 = "md5_1",
            },
            {
                cloud_id = "b2",
                percent = 0.1,
                status = "complete",
                last_read_ts = 1700000200,
                partial_md5 = "md5_2",
            },
        }

        local merged, changed = Sync.collectAndUploadLocalProgress(catalog, device_books, {})
        Cloud.uploadString = orig_upload
        Cloud.isConfigured = orig_cfg

        assert.is_true(changed)
        assert.is_not_nil(uploaded_payload)
        assert.are.equal("reading", merged.b1.status)
        assert.are.equal(0.64, merged.b1.percent)
        assert.are.equal("finished", merged.b2.status)
        assert.are.equal(1, merged.b2.percent)
    end)
end)
