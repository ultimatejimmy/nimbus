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

    it("reuploadFixedCovers upgrades entries without v2_ cover_etag and skips already-upgraded ones", function()
        local Covers = require("nimbus_covers")
        local orig_cfg = Cloud.isConfigured
        local orig_up_file = Cloud.uploadFile
        local orig_up_str = Cloud.uploadString
        local orig_extract = Covers.extractLocalCoverToFile

        local uploaded_files = {}
        local saved_catalog = false
        Cloud.isConfigured = function() return true end
        Cloud.uploadFile = function(rel, local_p, cb)
            table.insert(uploaded_files, rel)
            if cb then cb(true) end
        end
        Cloud.uploadString = function(rel, body, mime, cb)
            if rel == "_sync/catalog.json" then saved_catalog = true end
            if cb then cb(true) end
        end
        Covers.extractLocalCoverToFile = function(fp, dest)
            local f = io.open(dest, "wb")
            if f then f:write("clean-rgb24"); f:close() end
            return true
        end

        local catalog = {
            books = {
                old1 = { id = "old1", title = "Old Cover", folder = "Books/Old", cover_etag = "12345", deleted = false },
                new1 = { id = "new1", title = "V2 Cover", folder = "Books/New", cover_etag = "v2_99999", deleted = false },
            },
        }
        local device_books = {
            { cloud_id = "old1", local_path = "tests/tmp/old1.epub" },
            { cloud_id = "new1", local_path = "tests/tmp/new1.epub" },
        }

        local count, cat_changed = Sync.reuploadFixedCovers(catalog, device_books)

        Cloud.isConfigured = orig_cfg
        Cloud.uploadFile = orig_up_file
        Cloud.uploadString = orig_up_str
        Covers.extractLocalCoverToFile = orig_extract

        assert.are.equal(1, count)
        assert.is_true(cat_changed)
        assert.is_true(saved_catalog)
        assert.are.equal(1, #uploaded_files)
        assert.are.equal("Books/Old/cover.jpg", uploaded_files[1])
        assert.is_true(tostring(catalog.books.old1.cover_etag):sub(1, 3) == "v2_")
    end)
end)
