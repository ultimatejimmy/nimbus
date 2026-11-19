--[[--
nimbus_hash.lua
Book hashing (KOReader partialMD5 + SHA-256) and deterministic annotation IDs.
--]]

local ok_util, util = pcall(require, "util")
local ok_sha2, sha2 = pcall(require, "ffi/sha2")
if not ok_sha2 then
    ok_sha2, sha2 = pcall(require, "sha2")
end

local Hash = {}

Hash.PARTIAL_MD5_OFFSETS = {
    0,
    1024,
    4096,
    16384,
    65536,
    262144,
    1048576,
    4194304,
    16777216,
    67108864,
    268435456,
    1073741824,
}

--- Computes KOReader-compatible partial_md5 for a file on disk.
function Hash.partialMD5(filepath)
    if not filepath then return nil end
    if ok_util and util and util.partialMD5 then
        local ok, res = pcall(util.partialMD5, filepath)
        if ok and res then return res end
    end
    if not ok_sha2 or not sha2 or not sha2.md5 then return nil end
    local f = io.open(filepath, "rb")
    if not f then return nil end
    local hasher = sha2.md5()
    for _, offset in ipairs(Hash.PARTIAL_MD5_OFFSETS) do
        local ok_seek = f:seek("set", offset)
        if not ok_seek then break end
        local sample = f:read(1024)
        if sample and #sample > 0 then
            hasher(sample)
        else
            break
        end
    end
    f:close()
    return hasher()
end

--- Computes lowercase hex SHA-256 of a file on disk.
function Hash.sha256File(filepath)
    if not filepath or not ok_sha2 or not sha2 then return nil end
    local f = io.open(filepath, "rb")
    if not f then return nil end
    local hasher = sha2.sha256()
    while true do
        local chunk = f:read(65536)
        if not chunk or #chunk == 0 then break end
        hasher(chunk)
    end
    f:close()
    return hasher()
end

--- Computes lowercase hex SHA-256 of a string.
function Hash.sha256String(str)
    if not ok_sha2 or not sha2 then return nil end
    return sha2.sha256(tostring(str or ""))
end

--- Generates a deterministic annotation ID matching spec/SCHEMA.md.
function Hash.annotationId(book_id, text, anchor)
    local norm_text = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local payload = tostring(book_id or "") .. "|" .. norm_text .. "|" .. tostring(anchor or "")
    local digest = Hash.sha256String(payload)
    if digest then
        return "ann_" .. digest:sub(1, 10)
    end
    return "ann_" .. string.format("%010x", os.time())
end

--- Computes lowercase 32-char MD5 hex of a string.
function Hash.md5Hex(str)
    if not ok_sha2 or not sha2 or not sha2.md5 then return nil end
    return sha2.md5(tostring(str or ""))
end

--- Generates an 8-char random lowercase alphanumeric book_id.
function Hash.generateBookId()
    local seed_str = tostring(os.time()) .. ":" .. tostring(os.clock()) .. ":" .. tostring(math.random(1, 1000000))
    local digest = Hash.sha256String(seed_str)
    if digest then
        return digest:sub(1, 8)
    end
    return string.format("%08x", os.time())
end

return Hash
