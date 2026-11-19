-- spec_helper.lua
-- Environment mocks for nimbus.koplugin unit tests.

package.loaded["gettext"] = function(str) return str end

package.loaded["logger"] = {
    info = function(...) end,
    warn = function(...) end,
    dbg = function(...) end,
    err = function(...) end,
    error = function(...) end,
}

local ok_dk, dkjson = pcall(require, "dkjson")
if ok_dk and dkjson then
    package.loaded["json"] = dkjson
end

local tmp_data_dir = "tests/tmp"
os.execute("mkdir -p " .. tmp_data_dir .. "/settings/nimbus")

package.loaded["datastorage"] = {
    getDataDir = function() return tmp_data_dir end,
    getSettingsDir = function() return tmp_data_dir .. "/settings" end,
}

package.loaded["device"] = {
    model = "TestKobo",
    screen = {
        getWidth = function() return 1080 end,
        getHeight = function() return 1440 end,
    },
}

return { tmp_dir = tmp_data_dir }
