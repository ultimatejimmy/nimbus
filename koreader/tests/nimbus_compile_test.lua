local lfs = require("libs/libkoreader-lfs")

describe("nimbus.koplugin LuaJIT compilation", function()
    it("compiles every .lua file in nimbus.koplugin without syntax, upvalue, or local-limit errors", function()
        local files = {}
        for name in lfs.dir("nimbus.koplugin") do
            if name:sub(-4) == ".lua" then
                table.insert(files, name)
            end
        end
        table.sort(files)
        assert.is_true(#files >= 10)

        for _, name in ipairs(files) do
            local path = "nimbus.koplugin/" .. name
            local chunk, err = loadfile(path)
            assert.is_not_nil(chunk, "Failed to compile " .. path .. ": " .. tostring(err))
        end
    end)
end)
