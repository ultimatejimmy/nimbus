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
    end)

    it("automatically imports backup_cloud_tokens.lua and backup.lua cloud_provider", function()
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
        assert.are.equal("gdrive", cfg.provider)
        assert.is_true(Cloud.isConfigured("gdrive"))

        local imported = OAuth.loadTokens("gdrive")
        assert.are.equal("ya29.test_access", imported.access_token)
        assert.are.equal("1//test_refresh", imported.refresh_token)
    end)

    it("auto-imports even when existing nimbus settings.lua has provider = none and not user-selected", function()
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
        assert.are.equal("gdrive", cfg.provider)
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
end)
