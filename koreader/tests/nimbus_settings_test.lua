local Settings = require("nimbus_settings")
local OAuth = require("nimbus_cloud_oauth")
local Cloud = require("nimbus_cloud")

describe("nimbus_settings backup.koplugin auto-import", function()
    before_each(function()
        Settings.clearCache()
        OAuth.clearCache()
        os.remove("tests/tmp/settings/backup.lua")
        os.remove("tests/tmp/settings/backup_cloud_tokens.lua")
        os.remove("tests/tmp/settings/backup_cloud_creds.lua")
        os.remove("tests/tmp/settings/nimbus/settings.lua")
        os.remove("tests/tmp/settings/nimbus/oauth.lua")
        os.remove("tests/tmp/settings/nimbus/creds.lua")
        os.remove("tests/tmp/settings/nimbus/catalog_cache.lua")
    end)

    it("automatically selects backup slot from backup_cloud_tokens.lua and backup.lua cloud_provider without copying creds", function()
        Settings.writeLuaTable("tests/tmp/settings/backup.lua", {
            cloud_provider = "gdrive",
        })
        Settings.writeLuaTable("tests/tmp/settings/backup_cloud_tokens.lua", {
            gdrive = {
                access_token = "ya29.test_access",
                refresh_token = "1//test_refresh",
                expires_at = 9999999999,
            },
            dropbox = {
                access_token = "sl.test_dbx",
                refresh_token = "dbx_refresh",
            },
        })

        local available, _, tokens, backup_provider = Settings.detectBackupPluginAccounts()
        assert.are.equal("gdrive", backup_provider)
        assert.are.equal(2, #available)
        assert.is_not_nil(tokens.gdrive)

        local cfg = Settings.load()
        assert.are.equal("backup:gdrive", cfg.provider)
        assert.is_true(Cloud.isConfigured())
        assert.is_true(Cloud.isProviderConfigured("backup:gdrive"))
        assert.is_false(Cloud.isProviderConfigured("gdrive"))
        assert.is_nil(OAuth.loadTokens("gdrive"))

        local slot_tokens = OAuth.loadTokens("backup:gdrive")
        assert.are.equal("ya29.test_access", slot_tokens.access_token)
        assert.are.equal("1//test_refresh", slot_tokens.refresh_token)
    end)

    it("auto-selects backup slot even when existing nimbus settings.lua has provider = none and not user-selected", function()
        Settings.writeLuaTable("tests/tmp/settings/nimbus/settings.lua", {
            provider = "none",
            device_id = "TestKobo_1234",
        })
        Settings.writeLuaTable("tests/tmp/settings/backup.lua", {
            cloud_provider = "gdrive",
        })
        Settings.writeLuaTable("tests/tmp/settings/backup_cloud_tokens.lua", {
            gdrive = {
                access_token = "ya29.existing_none",
                refresh_token = "1//existing_none",
                expires_at = 9999999999,
            },
        })

        local cfg = Settings.load()
        assert.are.equal("backup:gdrive", cfg.provider)
        assert.is_true(Cloud.isConfigured())
    end)

    it("serializes and reloads tables containing functions, NaN, and special strings", function()
        local path = "tests/tmp/settings/nimbus/test_cache.lua"
        os.remove(path)
        local payload = {
            saved_at = 123456,
            catalog = {
                books = {
                    b1 = {
                        id = "b1",
                        title = 'Line1\nLine2 "Quoted" \\ Slash',
                        isbn = function() end,
                        bad_num = 0 / 0,
                    },
                },
            },
        }
        assert.is_true(Settings.writeLuaTable(path, payload))
        local loaded = Settings.readLuaTable(path)
        assert.are.equal("table", type(loaded))
        assert.are.equal(123456, loaded.saved_at)
        assert.are.equal('Line1\nLine2 "Quoted" \\ Slash', loaded.catalog.books.b1.title)
        assert.is_nil(loaded.catalog.books.b1.isbn)
        assert.is_nil(loaded.catalog.books.b1.bad_num)
        os.remove(path)
    end)

    it("detects and auto-imports Sink sink_sync from settings.reader.lua", function()
        os.remove("tests/tmp/settings.reader.lua")
        os.remove("tests/tmp/settings/sink_settings.lua")
        os.remove("tests/tmp/settings/kosync.lua")
        Settings.writeLuaTable("tests/tmp/settings.reader.lua", {
            sink_sync = {
                server_url = "https://sink.example.workers.dev/",
                username = "primary_reader",
                userkey = "sink_key_123",
            },
        })
        Settings.writeLuaTable("tests/tmp/settings/nimbus/settings.lua", {
            kosync_user_configured = true,
            kosync_enabled = true,
            kosync_username = "",
            kosync_userkey = "",
        })

        local cfg = Settings.load()
        assert.is_true(cfg.kosync_enabled)
        assert.are.equal("sink", cfg.kosync_source)
        assert.are.equal("https://sink.example.workers.dev", cfg.kosync_server)
        assert.are.equal("primary_reader", cfg.kosync_username)
        assert.are.equal("sink_key_123", cfg.kosync_userkey)
        os.remove("tests/tmp/settings.reader.lua")
    end)

    it("disconnects backup slot without modifying backup.koplugin or re-selecting on reload", function()
        local Sync = require("nimbus_sync")
        Settings.writeLuaTable("tests/tmp/settings/backup.lua", {
            cloud_provider = "gdrive",
        })
        Settings.writeLuaTable("tests/tmp/settings/backup_cloud_tokens.lua", {
            gdrive = {
                access_token = "ya29.backup_keep",
                refresh_token = "1//backup_keep",
                expires_at = 9999999999,
            },
        })
        local cfg = Settings.load()
        assert.are.equal("backup:gdrive", cfg.provider)
        Sync.saveCachedCatalog({ books = { b1 = { id = "b1", title = "Test" } } }, {})
        assert.is_not_nil(Settings.readLuaTable("tests/tmp/settings/nimbus/catalog_cache.lua"))

        assert.is_true(Cloud.disconnectProvider("backup:gdrive"))
        assert.are.equal("none", Settings.load().provider)
        assert.is_true(Settings.load().provider_user_selected)
        assert.is_false(Cloud.isConfigured())
        assert.is_nil(Settings.readLuaTable("tests/tmp/settings/nimbus/catalog_cache.lua"))

        -- Reloading settings must stay disconnected and backup tokens must remain intact
        Settings.clearCache()
        OAuth.clearCache()
        assert.are.equal("none", Settings.load().provider)
        local backup_after = Settings.readLuaTable("tests/tmp/settings/backup_cloud_tokens.lua")
        assert.are.equal("1//backup_keep", backup_after.gdrive.refresh_token)
    end)

    it("disconnects standalone OAuth and WebDAV providers cleanly", function()
        OAuth.saveTokens("gdrive", { access_token = "ya29.standalone", refresh_token = "1//standalone" })
        local cfg = Settings.load()
        cfg.provider = "gdrive"
        cfg.provider_user_selected = true
        Settings.save(cfg)
        assert.is_true(Cloud.isConfigured("gdrive"))

        assert.is_true(Cloud.disconnectProvider("gdrive"))
        assert.are.equal("none", Settings.load().provider)
        assert.is_false(Cloud.isProviderConfigured("gdrive"))
        assert.is_nil(OAuth.loadTokens("gdrive"))

        Cloud.saveCredentials("webdav", { url = "https://dav.example.com", username = "u", password = "p" })
        cfg = Settings.load()
        cfg.provider = "webdav"
        Settings.save(cfg)
        assert.is_true(Cloud.isConfigured("webdav"))

        assert.is_true(Cloud.disconnectProvider("webdav"))
        assert.are.equal("none", Settings.load().provider)
        assert.is_false(Cloud.isProviderConfigured("webdav"))
    end)
end)
