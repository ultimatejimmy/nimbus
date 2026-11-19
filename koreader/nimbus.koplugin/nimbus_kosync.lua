--[[--
nimbus_kosync.lua
Bidirectional KOSync v1 + Sink Cloudflare Worker progress bridge for
CrossPoint e-readers, Readest, and stock KOSync servers.
--]]

local Settings = require("nimbus_settings")
local Http = require("nimbus_http")
local Hash = require("nimbus_hash")

local KOSync = {}

function KOSync.hashPassword(password)
    return Hash.md5Hex(tostring(password or ""))
end

function KOSync.isConfigured(cfg)
    cfg = cfg or Settings.load()
    return cfg.kosync_enabled == true
        and type(cfg.kosync_server) == "string" and cfg.kosync_server ~= ""
        and type(cfg.kosync_username) == "string" and cfg.kosync_username ~= ""
        and type(cfg.kosync_userkey) == "string" and cfg.kosync_userkey ~= ""
end

function KOSync.getDocumentKey(filepath, method)
    if not filepath then return nil, {} end
    local filename = filepath:match("([^/\\]+)$") or filepath
    local fn_md5 = Hash.md5Hex(filename)
    local bin_md5 = Hash.partialMD5(filepath)
    local alts = {}
    if method == "binary" then
        if fn_md5 and fn_md5 ~= bin_md5 then table.insert(alts, fn_md5) end
        return bin_md5 or fn_md5, alts
    end
    if bin_md5 and bin_md5 ~= fn_md5 then table.insert(alts, bin_md5) end
    return fn_md5 or bin_md5, alts
end

local function makeHeaders(username, userkey, has_body)
    local h = {
        ["Accept"] = "application/vnd.koreader.v1+json, application/json",
        ["x-auth-user"] = tostring(username or ""),
        ["x-auth-key"] = tostring(userkey or ""),
    }
    if has_body then
        h["Content-Type"] = "application/json"
    end
    return h
end

function KOSync.testConnection(server, username, userkey, cb)
    local base = tostring(server or ""):gsub("/+$", "")
    if base == "" or tostring(username or "") == "" or tostring(userkey or "") == "" then
        return cb(false, "Server URL, username, and password are required")
    end
    local _, code, _, status, body = Http.request{
        url = base .. "/users/auth",
        method = "GET",
        headers = makeHeaders(username, userkey, false),
        block_timeout = 8,
        total_timeout = 12,
    }
    if code == 200 then
        return cb(true, username)
    end
    local decoded = Http.jsonDecode(body)
    local err_msg = (decoded and (decoded.message or decoded.error)) or status or tostring(code)
    return cb(false, err_msg)
end

function KOSync.pullProgress(filepath, doc_props, cb)
    local cfg = Settings.load()
    if not KOSync.isConfigured(cfg) then
        return cb(false, "not_configured")
    end
    local doc_key, alts = KOSync.getDocumentKey(filepath, cfg.kosync_checksum_method)
    if not doc_key then
        return cb(false, "no_document_key")
    end

    local params = {}
    doc_props = doc_props or {}
    if doc_props.title and doc_props.title ~= "" then
        table.insert(params, "title=" .. Http.urlEncode(doc_props.title))
    end
    if doc_props.authors and doc_props.authors ~= "" then
        local a = type(doc_props.authors) == "table" and table.concat(doc_props.authors, ", ") or tostring(doc_props.authors)
        table.insert(params, "authors=" .. Http.urlEncode(a))
    end
    if #alts > 0 then
        table.insert(params, "alt_hashes=" .. Http.urlEncode(table.concat(alts, ",")))
    end

    local base = cfg.kosync_server:gsub("/+$", "")
    local url = base .. "/syncs/progress/" .. Http.urlEncodePath(doc_key)
    if #params > 0 then
        url = url .. "?" .. table.concat(params, "&")
    end

    local _, code, _, status, body = Http.request{
        url = url,
        method = "GET",
        headers = makeHeaders(cfg.kosync_username, cfg.kosync_userkey, false),
        block_timeout = 5,
        total_timeout = 10,
    }
    if code ~= 200 then
        return cb(false, status or tostring(code))
    end
    local data = Http.jsonDecode(body)
    if type(data) ~= "table" or not data.percentage then
        return cb(false, "empty")
    end
    cb(true, {
        percent = tonumber(data.percentage) or 0,
        xpointer = data.progress,
        device_id = data.device_id or data.device or "KOSync",
        updated_at = tonumber(data.timestamp) or os.time(),
    })
end

function KOSync.pushProgress(filepath, doc_props, prog_state, cb)
    local cfg = Settings.load()
    if not KOSync.isConfigured(cfg) or not prog_state then
        if cb then cb(false, "not_configured") end
        return
    end
    local doc_key, alts = KOSync.getDocumentKey(filepath, cfg.kosync_checksum_method)
    if not doc_key then
        if cb then cb(false, "no_document_key") end
        return
    end

    doc_props = doc_props or {}
    local authors_str = type(doc_props.authors) == "table" and table.concat(doc_props.authors, ", ") or doc_props.authors
    local payload = {
        document = doc_key,
        progress = prog_state.xpointer or tostring(prog_state.page or "0"),
        percentage = tonumber(prog_state.percent) or 0,
        device = cfg.device_id,
        device_id = cfg.device_id,
        title = doc_props.title,
        authors = authors_str,
        alt_hashes = (#alts > 0) and alts or nil,
    }

    local base = cfg.kosync_server:gsub("/+$", "")
    local _, code, _, status = Http.request{
        url = base .. "/syncs/progress",
        method = "PUT",
        headers = makeHeaders(cfg.kosync_username, cfg.kosync_userkey, true),
        body = Http.jsonEncode(payload),
        block_timeout = 5,
        total_timeout = 10,
    }
    if cb then
        cb(code == 200 or code == 201, status or tostring(code))
    end
end

return KOSync
