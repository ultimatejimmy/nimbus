--[[--
nimbus_http.lua
Shared HTTP/HTTPS request, URL encoding, and streaming file source/sink helpers.
--]]

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")
local ok_ltn, ltn12 = pcall(require, "ltn12")
local ok_su, socketutil = pcall(require, "socketutil")
local ok_json, json = pcall(require, "json")
if not ok_json or not json then
    ok_json, json = pcall(require, "dkjson")
end

local Http = {}

function Http.urlEncode(str)
    if not str then return "" end
    str = tostring(str)
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w %-%_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    str = str:gsub(" ", "+")
    return str
end

function Http.urlEncodePath(str)
    if not str then return "" end
    return (tostring(str):gsub("([^%w%-%_%.%~%/])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function Http.makeFormData(tbl)
    local parts = {}
    for k, v in pairs(tbl or {}) do
        if v ~= nil then
            table.insert(parts, Http.urlEncode(k) .. "=" .. Http.urlEncode(v))
        end
    end
    return table.concat(parts, "&")
end

function Http.jsonEncode(val)
    if json and json.encode then return json.encode(val) end
    return "{}"
end

function Http.jsonDecode(str)
    if not str or str == "" or not json or not json.decode then return nil end
    local ok, data = pcall(json.decode, str)
    if ok then return data end
    return nil
end

function Http.makeFileProgressSource(file_handle, total_expected, on_progress, is_canceled)
    local sent = 0
    local finalized = false
    local chunk_size = 65536
    return function()
        if is_canceled and is_canceled() then
            return nil, "canceled"
        end
        if total_expected and total_expected > 0 and sent >= total_expected then
            if on_progress and not finalized then
                finalized = true
                on_progress(total_expected, total_expected, "finalizing")
            end
            return nil
        end
        local chunk = file_handle:read(chunk_size)
        if not chunk or #chunk == 0 then
            if on_progress and not finalized then
                finalized = true
                on_progress(total_expected or sent, total_expected or sent, "finalizing")
            end
            return nil
        end
        sent = sent + #chunk
        if on_progress then
            local total = total_expected and total_expected > 0 and total_expected or sent
            on_progress(math.min(sent, total), total, "uploading")
        end
        return chunk
    end
end

function Http.makeFileProgressSink(file_handle, total_expected, on_progress, is_canceled)
    local received = 0
    return function(chunk, err)
        if is_canceled and is_canceled() then
            return nil, "canceled"
        end
        if chunk == nil then
            if file_handle then file_handle:close() end
            if on_progress then
                local total = (total_expected and total_expected > 0) and total_expected or received
                on_progress(total, total, "done")
            end
            return 1
        end
        if chunk ~= "" then
            file_handle:write(chunk)
            received = received + #chunk
            if on_progress then
                local total = (total_expected and total_expected > 0) and total_expected or received
                on_progress(received, total, "downloading")
            end
        end
        return 1
    end
end

function Http.request(req)
    if not ok_ltn or not ltn12 then
        return nil, "ltn12 not available", nil, nil, ""
    end
    local url = req.url or ""
    local is_ssl = url:match("^https://")
    local client = is_ssl and https or http
    if is_ssl and not ok_https then
        return nil, "ssl.https not available", nil, nil, ""
    end
    if not is_ssl and not ok_http then
        return nil, "socket.http not available", nil, nil, ""
    end

    local resp_body = {}
    local sink = req.sink or ltn12.sink.table(resp_body)
    local source = req.source
    local headers = {}
    for k, v in pairs(req.headers or {}) do
        headers[k] = v
    end
    if not headers["User-Agent"] then
        headers["User-Agent"] = "Nimbus-KOReader/0.1.0"
    end
    if req.body ~= nil and not source then
        source = ltn12.source.string(req.body)
        if not headers["Content-Length"] then
            headers["Content-Length"] = tostring(#req.body)
        end
    end

    local prev_block, prev_total
    if ok_su and socketutil and socketutil.set_timeout then
        prev_block = socketutil.block_timeout
        prev_total = socketutil.total_timeout
        pcall(function()
            socketutil:set_timeout(req.block_timeout or 15, req.total_timeout or 60)
        end)
    end

    local ok_call, r, code, resp_headers, status = pcall(client.request, {
        url = url,
        method = req.method or "GET",
        headers = headers,
        source = source,
        sink = sink,
    })

    if ok_su and socketutil then
        pcall(function()
            if prev_block and prev_total and socketutil.set_timeout then
                socketutil:set_timeout(prev_block, prev_total)
            elseif socketutil.reset_timeout then
                socketutil:reset_timeout()
            end
        end)
    end

    if not ok_call then
        return nil, tostring(r), nil, nil, ""
    end

    local body_str = req.sink and "" or table.concat(resp_body)
    return r, code, resp_headers, status, body_str
end

return Http
