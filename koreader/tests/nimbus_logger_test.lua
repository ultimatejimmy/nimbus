-- nimbus_logger_test.lua
-- Unit tests for nimbus_logger.lua (levels, dedup, 64 KB .old rotation, mirroring, sanitization).

local helper = require("spec_helper")

describe("nimbus_logger", function()
    local Logger
    local log_dir = helper.tmp_dir .. "/logger_test"
    local orig_klogger
    local mirrored_warns
    local mirrored_errs
    local mirrored_infos

    local function readAll(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end

    before_each(function()
        os.execute("mkdir -p " .. log_dir)
        mirrored_warns = {}
        mirrored_errs = {}
        mirrored_infos = {}

        orig_klogger = package.loaded["logger"]
        package.loaded["logger"] = {
            info = function(msg) table.insert(mirrored_infos, msg) end,
            warn = function(msg) table.insert(mirrored_warns, msg) end,
            err = function(msg) table.insert(mirrored_errs, msg) end,
            dbg = function() end,
        }

        package.loaded["nimbus_logger"] = nil
        Logger = require("nimbus_logger")
        Logger.init(log_dir)
        Logger.clear()
        Logger.debug_enabled = false
        Logger.max_size = 64 * 1024
    end)

    after_each(function()
        if Logger then
            Logger.clear()
        end
        package.loaded["logger"] = orig_klogger
        package.loaded["nimbus_logger"] = nil
    end)

    it("defaults max_size to 64 KB and resolves init path", function()
        assert.are.equal(64 * 1024, Logger.max_size)
        assert.are.equal(log_dir .. "/nimbus.log", Logger.getPath())
        assert.are.equal(log_dir .. "/nimbus.log.old", Logger.getOldPath())
    end)

    it("writes INFO, ACTION, WARN, ERROR and gates DEBUG behind debug_enabled", function()
        Logger.info("Info hello")
        Logger.action("User clicked sync")
        Logger.warn("Minor warning")
        Logger.err("Critical failure")
        Logger.debug("Hidden debug line")

        local content = readAll(Logger.getPath())
        assert.is_not_nil(content)
        assert.is_true(content:find("%[INFO%] Info hello") ~= nil)
        assert.is_true(content:find("%[ACTION%] User clicked sync") ~= nil)
        assert.is_true(content:find("%[WARN%] Minor warning") ~= nil)
        assert.is_true(content:find("%[ERROR%] Critical failure") ~= nil)
        assert.is_nil(content:find("Hidden debug line"))

        Logger.debug_enabled = true
        Logger.debug("Visible debug line")
        content = readAll(Logger.getPath())
        assert.is_true(content:find("%[DEBUG%] Visible debug line") ~= nil)
    end)

    it("mirrors only WARN and ERROR to KOReader logger with Nimbus prefix", function()
        Logger.info("Normal info")
        Logger.action("Normal action")
        Logger.warn("Sync timeout")
        Logger.err("Catalog corrupt")

        assert.are.equal(0, #mirrored_infos)
        assert.are.equal(1, #mirrored_warns)
        assert.are.equal("Nimbus: Sync timeout", mirrored_warns[1])
        assert.are.equal(1, #mirrored_errs)
        assert.are.equal("Nimbus: Catalog corrupt", mirrored_errs[1])
    end)

    it("deduplicates identical consecutive INFO messages within the window", function()
        Logger.info("Repeated message")
        Logger.info("Repeated message")
        Logger.info("Different message")
        Logger.warn("Repeated warn")
        Logger.warn("Repeated warn")

        local content = readAll(Logger.getPath())
        local _, info_count = content:gsub("Repeated message", "")
        local _, warn_count = content:gsub("Repeated warn", "")
        assert.are.equal(1, info_count)
        assert.are.equal(2, warn_count)
    end)

    it("rotates nimbus.log to nimbus.log.old when exceeding 64 KB", function()
        local path = Logger.getPath()
        local old_path = Logger.getOldPath()

        -- Pre-fill nimbus.log past 64 KB
        local fh = io.open(path, "wb")
        assert.is_not_nil(fh)
        fh:write(string.rep("X", 65 * 1024))
        fh:close()

        -- Trigger rotation with a new log entry
        Logger.info("First entry after rotation")

        local cur = readAll(path)
        local old = readAll(old_path)
        assert.is_not_nil(cur)
        assert.is_not_nil(old)
        assert.is_true(#cur < 1024)
        assert.is_true(cur:find("First entry after rotation") ~= nil)
        assert.is_nil(cur:find("XXXXX"))
        assert.is_true(#old >= 65 * 1024)

        -- Trigger a second rotation and ensure .old is overwritten cleanly
        local fh2 = io.open(path, "wb")
        fh2:write(string.rep("Y", 65 * 1024))
        fh2:close()

        Logger.info("Second rotation entry")
        local cur2 = readAll(path)
        local old2 = readAll(old_path)
        assert.is_true(cur2:find("Second rotation entry") ~= nil)
        assert.is_true(old2:find("YYYYY") ~= nil)
        assert.is_nil(old2:find("XXXXX"))
    end)

    it("writes session header and rotates first if already oversized", function()
        local path = Logger.getPath()
        local fh = io.open(path, "wb")
        fh:write(string.rep("Z", 65 * 1024))
        fh:close()

        Logger.startSession("2026.11.19")

        local cur = readAll(path)
        local old = readAll(Logger.getOldPath())
        assert.is_not_nil(old)
        assert.is_true(cur:find("Nimbus Session Started:") ~= nil)
        assert.is_true(cur:find("%(v2026%.11%.19%)") ~= nil)
        assert.is_nil(cur:find("ZZZZZ"))
    end)

    it("clears both nimbus.log and nimbus.log.old", function()
        local path = Logger.getPath()
        local old_path = Logger.getOldPath()
        local fh = io.open(path, "wb")
        fh:write(string.rep("A", 65 * 1024))
        fh:close()
        Logger.info("Trigger old file")
        assert.is_not_nil(readAll(path))
        assert.is_not_nil(readAll(old_path))

        Logger.clear()
        assert.is_nil(readAll(path))
        assert.is_nil(readAll(old_path))
    end)

    it("sanitizes sensitive query parameters in URLs", function()
        local raw = "https://api.example.com/v1/file?access_token=secret123&id=42&api_key=abc&code=xyz"
        local clean = Logger.sanitizeUrl(raw)
        assert.is_nil(clean:find("secret123"))
        assert.is_nil(clean:find("abc"))
        assert.is_nil(clean:find("xyz"))
        assert.is_true(clean:find("id=42") ~= nil)
        assert.is_true(clean:find("access_token=REDACTED") ~= nil)
        assert.is_true(clean:find("api_key=REDACTED") ~= nil)
        assert.is_true(clean:find("code=REDACTED") ~= nil)
    end)
end)
