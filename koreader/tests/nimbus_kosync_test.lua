local Settings = require("nimbus_settings")
local KOSync = require("nimbus_kosync")
local Sync = require("nimbus_sync")
local Http = require("nimbus_http")
local Covers = require("nimbus_covers")

describe("nimbus_kosync, Sink auto-import, and catalog cache", function()
    before_each(function()
        Settings.clearCache()
        os.remove("tests/tmp/settings/sink_settings.lua")
        os.remove("tests/tmp/settings/kosync.lua")
        os.remove("tests/tmp/settings/nimbus/settings.lua")
        os.remove("tests/tmp/settings/nimbus/catalog_cache.lua")
    end)

    it("hashes passwords with MD5 and computes filename document keys", function()
        local digest = KOSync.hashPassword("secret")
        assert.are.equal(32, #digest)
        assert.are.equal("5ebe2294ecd0e0f08eab7690d2a6ee69", digest)

        local tmp_book = "tests/tmp/kosync_sample.epub"
        local wf = assert(io.open(tmp_book, "wb"))
        wf:write("kosync-sample-bytes")
        wf:close()

        local key, alts = KOSync.getDocumentKey(tmp_book, "filename")
        assert.are.equal(KOSync.hashPassword("kosync_sample.epub"), key)
        assert.is_true(#alts == 1)
    end)

    it("auto-imports Sink settings from sink_settings.lua", function()
        Settings.writeLuaTable("tests/tmp/settings/sink_settings.lua", {
            sink_sync = {
                server_url = "https://sink.example.workers.dev/",
                username = "jimmy",
                userkey = "5ebe2294ecd0e0f08eab7690d2a6ee69",
                checksum_method = "filename",
            },
        })

        local cfg = Settings.load()
        assert.is_true(cfg.kosync_enabled)
        assert.are.equal("https://sink.example.workers.dev", cfg.kosync_server)
        assert.are.equal("jimmy", cfg.kosync_username)
        assert.are.equal("5ebe2294ecd0e0f08eab7690d2a6ee69", cfg.kosync_userkey)
        assert.are.equal("filename", cfg.kosync_checksum_method)
        assert.is_true(KOSync.isConfigured(cfg))
    end)

    it("round-trips catalog_cache.lua locally", function()
        local cat = {
            version = 1,
            books = {
                ["b1"] = { id = "b1", title = "Cached Book" },
            },
        }
        local prog = {
            ["b1"] = { percent = 0.55, status = "reading", updated_at = 1700000000 },
        }
        assert.is_true(Sync.saveCachedCatalog(cat, prog))

        local loaded_cat, loaded_prog, saved_at = Sync.loadCachedCatalog()
        assert.are.equal("Cached Book", loaded_cat.books["b1"].title)
        assert.are.equal(0.55, loaded_prog["b1"].percent)
        assert.is_true(saved_at > 0)
    end)

    it("sends KOSync/Sink headers and parses progress responses", function()
        Settings.save({
            kosync_enabled = true,
            kosync_server = "https://sink.example.workers.dev",
            kosync_username = "jimmy",
            kosync_userkey = "abc123key",
            kosync_checksum_method = "filename",
            device_id = "TestDevice",
        })

        local orig_req = Http.request
        local captured = {}
        Http.request = function(req)
            table.insert(captured, req)
            if req.method == "GET" then
                return 1, 200, {}, "200 OK", Http.jsonEncode({
                    percentage = 0.72,
                    progress = "/body/DocFragment[4]/body/p[12]",
                    device_id = "CrossPoint_X4",
                    timestamp = 1700000100,
                })
            end
            return 1, 200, {}, "200 OK", "{}"
        end

        local pulled
        KOSync.pullProgress("tests/tmp/kosync_sample.epub", { title = "Sample", authors = "Author" }, function(ok, res)
            assert.is_true(ok)
            pulled = res
        end)
        assert.are.equal(0.72, pulled.percent)
        assert.are.equal("CrossPoint_X4", pulled.device_id)
        assert.are.equal("jimmy", captured[1].headers["x-auth-user"])
        assert.are.equal("abc123key", captured[1].headers["x-auth-key"])

        local pushed_ok = false
        KOSync.pushProgress("tests/tmp/kosync_sample.epub", { title = "Sample" }, {
            percent = 0.75,
            xpointer = "/body/DocFragment[5]",
        }, function(ok)
            pushed_ok = ok
        end)
        Http.request = orig_req

        assert.is_true(pushed_ok)
        assert.are.equal("PUT", captured[2].method)
        local body_tbl = Http.jsonDecode(captured[2].body)
        assert.are.equal(0.75, body_tbl.percentage)
        assert.are.equal("TestDevice", body_tbl.device_id)
    end)

    it("detects KOReader KOSync when Sink is absent, prefers Sink when both exist, and computes aspect-preserving cover fit", function()
        Settings.writeLuaTable("tests/tmp/settings/kosync.lua", {
            settings = {
                username = "ko_user",
                userkey = "ko_md5_key",
                checksum_method = 0,
            },
        })
        local cfg = Settings.load()
        assert.is_true(cfg.kosync_enabled)
        assert.are.equal("https://sync.koreader.rocks", cfg.kosync_server)
        assert.are.equal("ko_user", cfg.kosync_username)
        assert.are.equal("binary", cfg.kosync_checksum_method)
        assert.are.equal("kosync", cfg.kosync_source)
        assert.is_not_nil(Settings.consumeSyncImportNotice())

        Settings.writeLuaTable("tests/tmp/settings/sink_settings.lua", {
            sink_sync = {
                server_url = "https://sink.example.workers.dev",
                username = "sink_user",
                userkey = "sink_key",
                checksum_method = "filename",
            },
        })
        local detected = Settings.detectSyncPlugins()
        assert.are.equal(2, #detected)
        assert.are.equal("sink", detected[1].id)
        assert.are.equal("kosync", detected[2].id)

        local fw, fh = Covers.computeFitSize(600, 900, 150, 150)
        assert.are.equal(100, fw)
        assert.are.equal(150, fh)
    end)
end)
