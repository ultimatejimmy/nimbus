--[[--
nimbus_conductor.lua
Zero-hard-dependency adapter for Storefront's Memory Conductor (storefront_conductor).
Handles lazy loading regardless of alphabetical plugin load order and provides
safe standalone fallbacks when Storefront is not installed.
--]]

local NimbusConductor = {}

local _profile = nil
local _registered_mod = nil

local function getConductor()
    local ok, Conductor = pcall(require, "storefront_conductor")
    if ok and type(Conductor) == "table" then
        return Conductor
    end
    return nil
end

--- Stores the plugin profile for lazy registration with storefront_conductor.
--- @param profile table { plugin, is_foreground, on_reclaim, on_cancel_bg }
function NimbusConductor.setProfile(profile)
    _profile = profile
    _registered_mod = nil
    NimbusConductor.ensureRegistered()
end

--- Lazily registers the stored profile with storefront_conductor if loaded and not yet registered.
--- @return boolean registered
function NimbusConductor.ensureRegistered()
    if not _profile then return false end
    local Conductor = getConductor()
    if not Conductor or type(Conductor.registerPlugin) ~= "function" then
        return false
    end
    if _registered_mod == Conductor then
        return true
    end
    local ok = pcall(Conductor.registerPlugin, _profile)
    if ok then
        _registered_mod = Conductor
        return true
    end
    return false
end

--- Requests an execution slot from storefront_conductor, or runs immediately if unavailable.
--- @param opts table Conductor.requestSlot options
function NimbusConductor.requestSlot(opts)
    if type(opts) ~= "table" or type(opts.run) ~= "function" then
        return nil
    end
    NimbusConductor.ensureRegistered()
    local Conductor = getConductor()
    if Conductor and type(Conductor.requestSlot) == "function" then
        return Conductor.requestSlot(opts)
    end
    opts.run(function() end)
    return nil
end

--- Triggers a cross-plugin memory reclaim if storefront_conductor is available.
function NimbusConductor.reclaimMemory(level, exclude_plugin)
    local Conductor = getConductor()
    if Conductor and type(Conductor.reclaimMemory) == "function" then
        return Conductor.reclaimMemory(level, exclude_plugin)
    end
    return nil
end

--- Returns diagnostic memory status from storefront_conductor, or nil if unavailable.
function NimbusConductor.getMemoryStatus()
    local Conductor = getConductor()
    if Conductor and type(Conductor.getMemoryStatus) == "function" then
        return Conductor.getMemoryStatus()
    end
    return nil
end

--- Returns session intervention counters from storefront_conductor, or nil if unavailable.
function NimbusConductor.getStats()
    local Conductor = getConductor()
    if Conductor and type(Conductor.getStats) == "function" then
        return Conductor.getStats()
    end
    return nil
end

return NimbusConductor
