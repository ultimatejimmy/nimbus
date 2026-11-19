-- spec_runner.lua
-- Zero-dependency unit test runner for nimbus.koplugin using KOReader's bundled LuaJIT.

local AppDir = os.getenv("KOREADER_APP_DIR")
if not AppDir or not io.open(AppDir .. "/luajit", "r") then
    local candidates = {
        "/usr/lib/koreader",
        "/home/jimmy/squashfs-root/usr/lib/koreader",
        "/home/" .. (os.getenv("USER") or "user") .. "/squashfs-root/usr/lib/koreader",
    }
    for _, dir in ipairs(candidates) do
        local f = io.open(dir .. "/luajit", "r")
        if f then
            f:close()
            AppDir = dir
            break
        end
    end
end
AppDir = AppDir or "/usr/lib/koreader"

package.path = package.path .. ";" .. AppDir .. "/?.lua"
package.path = package.path .. ";" .. AppDir .. "/common/?.lua"
package.path = package.path .. ";" .. AppDir .. "/libs/?.lua"
package.path = package.path .. ";" .. AppDir .. "/frontend/?.lua"
package.path = package.path .. ";" .. AppDir .. "/ffi/?.lua"
package.path = package.path .. ";nimbus.koplugin/?.lua;./nimbus.koplugin/?.lua;../nimbus.koplugin/?.lua;?.lua;tests/?.lua"

package.cpath = package.cpath .. ";" .. AppDir .. "/libs/?.so"
package.cpath = package.cpath .. ";" .. AppDir .. "/libs/libkoreader-?.so"
package.cpath = package.cpath .. ";" .. AppDir .. "/common/?.so"
package.cpath = package.cpath .. ";" .. AppDir .. "/?.so"

local ok_lfs, real_lfs = pcall(require, "libs/libkoreader-lfs")
if not (ok_lfs and type(real_lfs) == "table") then
    ok_lfs, real_lfs = pcall(require, "lfs")
end
if ok_lfs and type(real_lfs) == "table" then
    package.preload["libs/libkoreader-lfs"] = function() return real_lfs end
    package.loaded["libs/libkoreader-lfs"] = real_lfs
    package.loaded["lfs"] = real_lfs
    _G.lfs = real_lfs
end

local stats = { passed = 0, failed = 0, errors = {} }
local before_each_stack = {}
local after_each_stack = {}
local current_describe = {}

local function push_context()
    table.insert(before_each_stack, {})
    table.insert(after_each_stack, {})
end

local function pop_context()
    table.remove(before_each_stack)
    table.remove(after_each_stack)
end

_G.before_each = function(fn)
    local cur = before_each_stack[#before_each_stack]
    if cur then table.insert(cur, fn) end
end

_G.after_each = function(fn)
    local cur = after_each_stack[#after_each_stack]
    if cur then table.insert(cur, fn) end
end

_G.describe = function(name, fn)
    table.insert(current_describe, name)
    push_context()
    local ok, err = pcall(fn)
    if not ok then
        stats.failed = stats.failed + 1
        table.insert(stats.errors, { name = table.concat(current_describe, " -> "), err = err })
        print("[ERROR in describe] " .. table.concat(current_describe, " -> ") .. ": " .. tostring(err))
    end
    pop_context()
    table.remove(current_describe)
end

_G.it = function(name, fn)
    local full_name = table.concat(current_describe, " -> ") .. " -> " .. name
    for _, level in ipairs(before_each_stack) do
        for _, bfn in ipairs(level) do pcall(bfn) end
    end
    local ok, err = pcall(fn)
    for _, level in ipairs(after_each_stack) do
        for _, afn in ipairs(level) do pcall(afn) end
    end
    if ok then
        stats.passed = stats.passed + 1
    else
        stats.failed = stats.failed + 1
        table.insert(stats.errors, { name = full_name, err = err })
        print("[FAIL] " .. full_name .. "\n       " .. tostring(err))
    end
end

local function deep_compare(t1, t2)
    if t1 == t2 then return true end
    if type(t1) ~= "table" or type(t2) ~= "table" then return false end
    for k, v in pairs(t1) do
        if not deep_compare(v, t2[k]) then return false end
    end
    for k, _ in pairs(t2) do
        if t1[k] == nil then return false end
    end
    return true
end

_G.assert = setmetatable({
    are = {
        equal = function(exp, act, msg)
            if exp ~= act then
                error((msg or "Expected equal") .. ": expected " .. tostring(exp) .. ", got " .. tostring(act), 2)
            end
        end,
        same = function(exp, act, msg)
            if not deep_compare(exp, act) then
                error((msg or "Expected same table"), 2)
            end
        end,
    },
    is_true = function(v, msg)
        if not v then error(msg or ("Expected true, got " .. tostring(v)), 2) end
    end,
    is_false = function(v, msg)
        if v then error(msg or ("Expected false, got " .. tostring(v)), 2) end
    end,
    is_nil = function(v, msg)
        if v ~= nil then error(msg or ("Expected nil, got " .. tostring(v)), 2) end
    end,
    is_not_nil = function(v, msg)
        if v == nil then error(msg or "Expected non-nil", 2) end
    end,
}, {
    __call = function(_, ...)
        local cond, msg = ...
        if not cond then error(msg or "Assertion failed", 2) end
        return ...
    end
})

require("spec_helper")

local test_files = {
    "tests/nimbus_merge_test.lua",
    "tests/nimbus_hash_test.lua",
    "tests/nimbus_matcher_test.lua",
    "tests/nimbus_drivers_test.lua",
}

for _, tf in ipairs(test_files) do
    print("Running " .. tf .. "...")
    local chunk, err = loadfile(tf)
    if not chunk then
        stats.failed = stats.failed + 1
        print("[LOAD ERROR] " .. tf .. ": " .. tostring(err))
    else
        local ok, rerr = pcall(chunk)
        if not ok then
            stats.failed = stats.failed + 1
            print("[RUN ERROR] " .. tf .. ": " .. tostring(rerr))
        end
    end
end

print(string.format("\nResults: %d passed, %d failed", stats.passed, stats.failed))
if stats.failed > 0 then os.exit(1) end
os.exit(0)
