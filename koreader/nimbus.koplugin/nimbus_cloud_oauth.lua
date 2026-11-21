--[[--
nimbus_cloud_oauth.lua
OAuth2 Device Authorization Grant (RFC 8628) + token storage & refresh for nimbus.koplugin.
Supports importing existing OAuth tokens from backup.koplugin.
--]]

local _ = require("gettext")
local Constants = require("nimbus_constants")
local Logger = require("nimbus_logger")
local Settings = require("nimbus_settings")
local Http = require("nimbus_http")

local OAuth = {}

OAuth.PROVIDERS = {
    [Constants.CLOUD_PROVIDERS.GDRIVE] = {
        name = "Google Drive",
        device_code_url = "https://oauth2.googleapis.com/device/code",
        token_url = "https://oauth2.googleapis.com/token",
        default_scope = "https://www.googleapis.com/auth/drive.file",
        client_id = Constants.OAUTH_GDRIVE_CLIENT_ID,
        relay_url = Constants.OAUTH_DEFAULT_RELAY_URL,
    },
    [Constants.CLOUD_PROVIDERS.ONEDRIVE] = {
        name = "Microsoft OneDrive",
        device_code_url = "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode",
        token_url = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token",
        default_scope = "Files.ReadWrite offline_access",
        client_id = Constants.OAUTH_ONEDRIVE_CLIENT_ID,
    },
    [Constants.CLOUD_PROVIDERS.DROPBOX] = {
        name = "Dropbox",
        device_code_url = Constants.OAUTH_DEFAULT_RELAY_URL .. "/api/oauth/dropbox/init",
        token_url = "https://api.dropboxapi.com/oauth2/token",
        client_id = Constants.OAUTH_DROPBOX_CLIENT_ID,
        relay_url = Constants.OAUTH_DEFAULT_RELAY_URL,
    },
}

local _tokens_cache = nil

local function getTokensFilePath()
    return Settings.getNimbusDir() .. "/oauth.lua"
end

function OAuth.loadAllTokens()
    if _tokens_cache then return _tokens_cache end
    _tokens_cache = Settings.readLuaTable(getTokensFilePath()) or {}
    return _tokens_cache
end

function OAuth.saveAllTokens(tbl)
    _tokens_cache = tbl or {}
    return Settings.writeLuaTable(getTokensFilePath(), _tokens_cache)
end

local function resolveBaseProvider(provider)
    if type(provider) ~= "string" then return nil, false end
    local base = provider:match("^backup:(.+)$")
    if base then return base, true end
    return provider, false
end

function OAuth.loadTokens(provider)
    if not provider then return nil end
    local all = OAuth.loadAllTokens()
    if all[provider] then
        return all[provider]
    end
    local base, is_backup = resolveBaseProvider(provider)
    if is_backup and base then
        local _, _, backup_tokens = Settings.detectBackupPluginAccounts()
        local bt = backup_tokens and backup_tokens[base]
        if type(bt) == "table" and (bt.access_token or bt.refresh_token) then
            local copy = {}
            for k, v in pairs(bt) do copy[k] = v end
            return copy
        end
    end
    return nil
end

function OAuth.saveTokens(provider, tokens)
    if not provider then return false end
    local all = OAuth.loadAllTokens()
    all[provider] = tokens
    return OAuth.saveAllTokens(all)
end

function OAuth.clearTokens(provider)
    if not provider then return false end
    local all = OAuth.loadAllTokens()
    all[provider] = nil
    return OAuth.saveAllTokens(all)
end

function OAuth.clearCache()
    _tokens_cache = nil
end

function OAuth.requestDeviceCode(provider, opts, callback)
    opts = opts or {}
    local pdef = OAuth.PROVIDERS[provider]
    if not pdef then
        if callback then callback(false, "Unsupported OAuth provider: " .. tostring(provider)) end
        return
    end
    local client_id = opts.client_id or pdef.client_id
    local scope = opts.scope or pdef.default_scope
    local body = Http.makeFormData({
        client_id = client_id,
        scope = scope,
    })

    local _, code, _, _, resp_body = Http.request({
        url = pdef.device_code_url,
        method = "POST",
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
        body = body,
    })

    if code == 200 or code == 201 then
        local data = Http.jsonDecode(resp_body)
        if data and data.device_code and data.user_code then
            Logger.action("OAuth device code requested for " .. tostring(provider))
            if callback then
                callback(true, {
                    device_code = data.device_code,
                    user_code = data.user_code,
                    verification_url = data.verification_url or data.verification_uri or "https://www.google.com/device",
                    verification_uri_complete = data.verification_uri_complete or data.verification_url_complete,
                    expires_in = tonumber(data.expires_in) or 1800,
                    interval = tonumber(data.interval) or 5,
                })
            end
            return
        end
    end
    Logger.warn("OAuth device code request failed for " .. tostring(provider) .. " (HTTP " .. tostring(code) .. ")")
    if callback then callback(false, "Device code request failed (HTTP " .. tostring(code) .. "): " .. tostring(resp_body)) end
end

function OAuth.pollToken(provider, device_code, opts, callback)
    opts = opts or {}
    local pdef = OAuth.PROVIDERS[provider]
    if not pdef then
        if callback then callback(false, "Unsupported OAuth provider: " .. tostring(provider)) end
        return
    end

    local relay_url = opts.relay_url or pdef.relay_url
    local client_id = opts.client_id or pdef.client_id
    local url, headers, body

    if provider == Constants.CLOUD_PROVIDERS.GDRIVE and relay_url and relay_url ~= "" then
        url = relay_url:gsub("/+$", "") .. "/api/oauth/gdrive/poll"
        headers = { ["Content-Type"] = "application/json" }
        body = Http.jsonEncode({ device_code = device_code, client_id = client_id })
    elseif provider == Constants.CLOUD_PROVIDERS.DROPBOX and relay_url and relay_url ~= "" then
        url = relay_url:gsub("/+$", "") .. "/api/oauth/dropbox/poll"
        headers = { ["Content-Type"] = "application/json" }
        body = Http.jsonEncode({ device_code = device_code })
    else
        url = pdef.token_url
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        body = Http.makeFormData({
            client_id = client_id,
            device_code = device_code,
            grant_type = "urn:ietf:params:oauth:grant-type:device_code",
        })
    end

    local _, code, _, _, resp_body = Http.request({
        url = url,
        method = "POST",
        headers = headers,
        body = body,
    })

    local data = Http.jsonDecode(resp_body)
    if (code == 200 or code == 201) and data and data.access_token then
        local tokens = {
            access_token = data.access_token,
            refresh_token = data.refresh_token,
            token_type = data.token_type or "Bearer",
            expires_at = os.time() + (tonumber(data.expires_in) or 3600),
            scope = data.scope,
        }
        OAuth.saveTokens(provider, tokens)
        if callback then callback(true, tokens) end
        return
    end

    local err = (data and data.error) or ("http_" .. tostring(code))
    if callback then callback(false, err, data) end
end

function OAuth.refreshToken(provider, refresh_token, opts, callback)
    opts = opts or {}
    local base = resolveBaseProvider(provider)
    local pdef = OAuth.PROVIDERS[base]
    if not pdef or not refresh_token or refresh_token == "" then
        if callback then callback(false, "Missing refresh_token") end
        return
    end

    local relay_url = opts.relay_url or pdef.relay_url
    local client_id = opts.client_id or pdef.client_id
    local url, headers, body

    if base == Constants.CLOUD_PROVIDERS.GDRIVE and relay_url and relay_url ~= "" then
        url = relay_url:gsub("/+$", "") .. "/api/oauth/gdrive/refresh"
        headers = { ["Content-Type"] = "application/json" }
        body = Http.jsonEncode({ refresh_token = refresh_token, client_id = client_id })
    elseif base == Constants.CLOUD_PROVIDERS.DROPBOX and relay_url and relay_url ~= "" then
        url = relay_url:gsub("/+$", "") .. "/api/oauth/dropbox/refresh"
        headers = { ["Content-Type"] = "application/json" }
        body = Http.jsonEncode({ refresh_token = refresh_token })
    else
        url = pdef.token_url
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        body = Http.makeFormData({
            client_id = client_id,
            refresh_token = refresh_token,
            grant_type = "refresh_token",
        })
    end

    local _, code, _, _, resp_body = Http.request({
        url = url,
        method = "POST",
        headers = headers,
        body = body,
    })

    local data = Http.jsonDecode(resp_body)
    if (code == 200 or code == 201) and data and data.access_token then
        local existing = OAuth.loadTokens(provider) or {}
        existing.access_token = data.access_token
        if data.refresh_token and data.refresh_token ~= "" then
            existing.refresh_token = data.refresh_token
        end
        existing.expires_at = os.time() + (tonumber(data.expires_in) or 3600)
        OAuth.saveTokens(provider, existing)
        Logger.info("OAuth token refreshed for " .. tostring(provider))
        if callback then callback(true, existing) end
        return
    end

    Logger.warn("OAuth token refresh failed for " .. tostring(provider) .. " (HTTP " .. tostring(code) .. ")")
    if callback then callback(false, "Token refresh failed (HTTP " .. tostring(code) .. ")") end
end

function OAuth.getValidAccessToken(provider, opts, callback)
    local tokens = OAuth.loadTokens(provider)
    local base = resolveBaseProvider(provider)
    if not tokens or not tokens.access_token then
        if callback then callback(false, _("Not signed in to ") .. (OAuth.PROVIDERS[base] and OAuth.PROVIDERS[base].name or tostring(provider))) end
        return
    end
    local now = os.time()
    if tokens.expires_at and now < (tonumber(tokens.expires_at) - 120) then
        if callback then callback(true, tokens.access_token) end
        return
    end
    if tokens.refresh_token and tokens.refresh_token ~= "" then
        OAuth.refreshToken(provider, tokens.refresh_token, opts, function(ok, new_tokens_or_err)
            if ok and new_tokens_or_err then
                if callback then callback(true, new_tokens_or_err.access_token) end
            else
                if callback then callback(false, new_tokens_or_err) end
            end
        end)
        return
    end
    if callback then callback(true, tokens.access_token) end
end

return OAuth
