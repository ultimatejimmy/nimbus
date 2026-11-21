--[[--
nimbus_constants.lua
Shared constants, OAuth app registrations, and defaults for nimbus.koplugin.
--]]

local Constants = {}

Constants.VERSION = "26.11.20.4"
Constants.SCHEMA_VERSION = 1

Constants.CLOUD_PROVIDERS = {
    NONE = "none",
    GDRIVE = "gdrive",
    ONEDRIVE = "onedrive",
    DROPBOX = "dropbox",
    WEBDAV = "webdav",
}

Constants.DEFAULT_REMOTE_ROOT = "Nimbus"

-- OAuth2 app registrations (installed-app / device-code flow — client_id is public by design)
-- Isolated here so dedicated Nimbus OAuth apps can be swapped in at any time.
Constants.OAUTH_GDRIVE_CLIENT_ID = "444320595925-2mlkslggov1f25qv45th2tq3dl466f9u.apps.googleusercontent.com"
Constants.OAUTH_ONEDRIVE_CLIENT_ID = "982359c5-d74b-408c-8ff0-7d43c678195e"
Constants.OAUTH_DROPBOX_CLIENT_ID = "khboin1ohr74q7y"
Constants.OAUTH_DEFAULT_RELAY_URL = "https://backup.ultimatejimmy.workers.dev"

Constants.SUPPORTED_FORMATS = {
    epub = true,
    pdf = true,
    cbz = true,
    mobi = true,
    azw3 = true,
    fb2 = true,
}

Constants.WHISPERSYNC_FORWARD_THRESHOLD = 0.002
Constants.AUTO_SYNC_DEBOUNCE_SEC = 5

return Constants
