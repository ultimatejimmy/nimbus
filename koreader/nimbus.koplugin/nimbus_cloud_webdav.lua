--[[--
nimbus_cloud_webdav.lua
WebDAV hierarchical CloudFS driver for nimbus.koplugin.
--]]

local ok_ltn, ltn12 = pcall(require, "ltn12")
local ok_mime, mime = pcall(require, "mime")
local Http = require("nimbus_http")

local WebDAV = {}

local function base64Encode(str)
    if ok_mime and mime and mime.b64 then
        return mime.b64(str)
    end
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    return ((str:gsub(".", function(x)
        local r, bits = "", x:byte()
        for i = 8, 1, -1 do r = r .. (bits % 2 ^ i - bits % 2 ^ (i - 1) > 0 and "1" or "0") end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
        return b:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#str % 3 + 1])
end

local function makeHeaders(creds, extra)
    local h = {}
    if creds and creds.username and creds.username ~= "" then
        h["Authorization"] = "Basic " .. base64Encode(tostring(creds.username) .. ":" .. tostring(creds.password or ""))
    end
    for k, v in pairs(extra or {}) do
        h[k] = v
    end
    return h
end

local function buildUrl(creds, remote_path)
    local base = tostring((creds and creds.url) or ""):gsub("/+$", "")
    local rel = tostring(remote_path or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
    if rel == "" then return base .. "/" end
    return base .. "/" .. Http.urlEncodePath(rel)
end

local function urlDecode(str)
    return (tostring(str or ""):gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function ensureDirSync(creds, remote_dir)
    local rel = tostring(remote_dir or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
    if rel == "" then return true end
    local acc = ""
    for part in rel:gmatch("[^/]+") do
        acc = (acc == "") and part or (acc .. "/" .. part)
        local url = buildUrl(creds, acc) .. "/"
        local _, code = Http.request({
            url = url,
            method = "MKCOL",
            headers = makeHeaders(creds),
        })
        -- 201 Created, 405 Method Not Allowed (already exists), 301/302/409
        if code ~= 200 and code ~= 201 and code ~= 204 and code ~= 405 then
            -- Verify if it exists via PROPFIND Depth 0
            local _, pcode = Http.request({
                url = url,
                method = "PROPFIND",
                headers = makeHeaders(creds, { ["Depth"] = "0" }),
            })
            if pcode ~= 207 and pcode ~= 200 then
                return false, "WebDAV MKCOL failed for '" .. acc .. "' (HTTP " .. tostring(code) .. ")"
            end
        end
    end
    return true
end

function WebDAV.testConnection(creds, cb)
    if not creds or not creds.url or creds.url == "" then
        return cb(false, "WebDAV URL is not configured")
    end
    local _, code = Http.request({
        url = buildUrl(creds, ""),
        method = "PROPFIND",
        headers = makeHeaders(creds, { ["Depth"] = "0" }),
    })
    if code == 207 or code == 200 then
        return cb(true, creds.url)
    end
    cb(false, "WebDAV connection failed (HTTP " .. tostring(code) .. ")")
end

function WebDAV.ensurePath(remote_dir, creds, cb)
    local ok, err = ensureDirSync(creds, remote_dir)
    if ok then cb(true, remote_dir) else cb(false, err) end
end

function WebDAV.uploadString(remote_path, content_str, content_type, creds, cb)
    local dir = remote_path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
        local ok_dir, err = ensureDirSync(creds, dir)
        if not ok_dir then return cb(false, err) end
    end
    local _, code = Http.request({
        url = buildUrl(creds, remote_path),
        method = "PUT",
        headers = makeHeaders(creds, { ["Content-Type"] = content_type or "application/octet-stream" }),
        body = tostring(content_str or ""),
    })
    if code == 200 or code == 201 or code == 204 then return cb(true) end
    cb(false, "WebDAV PUT failed (HTTP " .. tostring(code) .. ")")
end

function WebDAV.uploadFile(remote_path, local_path, creds, cb, opts)
    opts = opts or {}
    local dir = remote_path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then
        local ok_dir, err = ensureDirSync(creds, dir)
        if not ok_dir then return cb(false, err) end
    end
    local f = io.open(local_path, "rb")
    if not f then return cb(false, "Cannot open local file: " .. tostring(local_path)) end
    local size = f:seek("end") or 0
    f:seek("set", 0)
    local _, code = Http.request({
        url = buildUrl(creds, remote_path),
        method = "PUT",
        headers = makeHeaders(creds, {
            ["Content-Type"] = "application/octet-stream",
            ["Content-Length"] = tostring(size),
        }),
        source = Http.makeFileProgressSource(f, size, opts.on_progress, opts.is_canceled),
        total_timeout = 300,
    })
    pcall(function() f:close() end)
    if opts.is_canceled and opts.is_canceled() then return cb(false, "canceled") end
    if code == 200 or code == 201 or code == 204 then return cb(true) end
    cb(false, "WebDAV file PUT failed (HTTP " .. tostring(code) .. ")")
end

function WebDAV.downloadString(remote_path, creds, cb)
    local _, code, _, _, body = Http.request({
        url = buildUrl(creds, remote_path),
        method = "GET",
        headers = makeHeaders(creds),
    })
    if code == 200 then return cb(true, body) end
    if code == 404 then return cb(false, "not_found") end
    cb(false, "WebDAV GET failed (HTTP " .. tostring(code) .. ")")
end

function WebDAV.downloadFile(remote_path, local_dest_path, creds, cb, opts)
    opts = opts or {}
    local f = io.open(local_dest_path, "wb")
    if not f then return cb(false, "Cannot write local file: " .. tostring(local_dest_path)) end
    local _, code = Http.request({
        url = buildUrl(creds, remote_path),
        method = "GET",
        headers = makeHeaders(creds),
        sink = Http.makeFileProgressSink(f, opts.expected_size or 0, opts.on_progress, opts.is_canceled),
        total_timeout = 300,
    })
    pcall(function() f:close() end)
    if opts.is_canceled and opts.is_canceled() then
        os.remove(local_dest_path)
        return cb(false, "canceled")
    end
    if code == 200 then return cb(true) end
    os.remove(local_dest_path)
    cb(false, "WebDAV file GET failed (HTTP " .. tostring(code) .. ")")
end

function WebDAV.listDir(remote_dir, creds, cb)
    local target_url = buildUrl(creds, remote_dir)
    if not target_url:match("/$") then target_url = target_url .. "/" end
    local _, code, _, _, body = Http.request({
        url = target_url,
        method = "PROPFIND",
        headers = makeHeaders(creds, {
            ["Depth"] = "1",
            ["Content-Type"] = "application/xml; charset=utf-8",
        }),
        body = [[<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>]],
    })
    if code == 404 then return cb(true, {}) end
    if code ~= 207 and code ~= 200 then
        return cb(false, "WebDAV PROPFIND failed (HTTP " .. tostring(code) .. ")")
    end

    local entries = {}
    local req_path = target_url:match("^https?://[^/]+(.*)$") or "/"
    req_path = req_path:gsub("/+$", "")
    local rel_dir = tostring(remote_dir or ""):gsub("^/+", ""):gsub("/+$", "")

    for resp in tostring(body or ""):gmatch("<[^>]*:?response[^>]*>(.-)</[^>]*:?response>") do
        local href = resp:match("<[^>]*:?href[^>]*>(.-)</[^>]*:?href>")
        if href then
            local clean_href = href:gsub("^https?://[^/]+", ""):gsub("/+$", "")
            local decoded_href = urlDecode(clean_href)
            if clean_href ~= req_path and decoded_href ~= urlDecode(req_path) then
                local name = decoded_href:match("([^/]+)$")
                if name and name ~= "" then
                    local is_dir = resp:match("<[^>]*:?collection%s*/?>") ~= nil or href:match("/$") ~= nil
                    local size = tonumber(resp:match("<[^>]*:?getcontentlength[^>]*>(%d+)</")) or 0
                    local mtime = resp:match("<[^>]*:?getlastmodified[^>]*>(.-)</")
                    local full_path = (rel_dir == "") and name or (rel_dir .. "/" .. name)
                    table.insert(entries, {
                        name = name,
                        path = full_path,
                        is_dir = is_dir,
                        size = size,
                        mtime = mtime,
                    })
                end
            end
        end
    end
    cb(true, entries)
end

function WebDAV.deletePath(remote_path, creds, cb)
    local _, code = Http.request({
        url = buildUrl(creds, remote_path),
        method = "DELETE",
        headers = makeHeaders(creds),
    })
    if code == 200 or code == 204 or code == 404 then return cb(true) end
    cb(false, "WebDAV DELETE failed (HTTP " .. tostring(code) .. ")")
end

return WebDAV
