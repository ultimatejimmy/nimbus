--[[--
localization_nimbus.lua
Localization Manager for Nimbus Plugin (with .po support, matching Storefront).
--]]

local ok_log, logger = pcall(require, "logger")
if not ok_log or not logger then
    logger = { info = function() end, warn = function() end }
end
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or type(lfs) ~= "table" then
    ok_lfs, lfs = pcall(require, "lfs")
end

local Localization = {
    current_language = "en",
    translations = {},
    available_languages = {},
    path = "plugins/nimbus.koplugin",
}

function Localization:parsePO(filepath)
    local translations = {}
    local file = io.open(filepath, "r")
    if not file then
        return nil
    end

    local msgid = nil
    local msgstr = nil
    local in_msgid = false
    local in_msgstr = false

    for line in file:lines() do
        line = line:gsub("[\r\t ]+$", "")
        if not (line:match("^#") or line:match("^%s*$")) then
            if line:match('^msgid%s+"') then
                if msgid and msgstr then
                    translations[msgid] = msgstr
                end
                msgid = line:match('^msgid%s+"(.*)"$')
                msgstr = nil
                in_msgid = true
                in_msgstr = false
            elseif line:match('^msgstr%s+"') then
                msgstr = line:match('^msgstr%s+"(.*)"$')
                in_msgid = false
                in_msgstr = true
            elseif line:match('^"') then
                local continuation = line:match('^"(.-)"') or ""
                if in_msgid and msgid then
                    msgid = msgid .. continuation
                elseif in_msgstr and msgstr then
                    msgstr = msgstr .. continuation
                end
            end
        end
    end

    if msgid and msgstr then
        translations[msgid] = msgstr
    end
    file:close()

    local function unescapePOString(str)
        if not str or type(str) ~= "string" then return str end
        local prev = str
        for _ = 1, 3 do
            local next_str = prev:gsub("\\(.)", function(c)
                if c == "n" then return "\n"
                elseif c == "t" then return "\t"
                elseif c == '"' then return '"'
                elseif c == "\\" then return "\\"
                else return c
                end
            end)
            if next_str == prev then break end
            prev = next_str
        end
        return prev
    end

    for key, value in pairs(translations) do
        local normalized_key = unescapePOString(key)
        local unescaped_val = unescapePOString(value)
        translations[normalized_key] = unescaped_val
        if normalized_key ~= key then
            translations[key] = nil
        end
    end

    return translations
end

local function resolveScriptDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    local dir = src:match("^@?(.*[/\\])") or "./"
    if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
        dir = dir:sub(1, -2)
    end
    return dir:gsub("\\", "/")
end

function Localization:languageExists(lang_code)
    for _, code in ipairs(self.available_languages) do
        if code == lang_code then return true end
    end
    return false
end

function Localization:detectSystemLanguage()
    local lang = nil
    if _G.G_reader_settings and type(_G.G_reader_settings.readSetting) == "function" then
        local ok_s, setting = pcall(function()
            return _G.G_reader_settings:readSetting("language") or _G.G_reader_settings:readSetting("lang")
        end)
        if ok_s and setting and type(setting) == "string" and #setting > 0 then
            lang = setting
        end
    end
    if not lang then
        local ok_gt, gt = pcall(require, "gettext")
        if ok_gt and type(gt) == "table" then
            if type(gt.lang) == "string" and #gt.lang > 0 then
                lang = gt.lang
            elseif type(gt.language) == "string" and #gt.language > 0 then
                lang = gt.language
            end
        end
    end
    if not lang then
        local env_lang = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES")
        if env_lang and #env_lang > 0 then
            lang = env_lang:match("^([^%.@]+)")
        end
    end
    if not lang then return "en" end

    lang = lang:gsub("-", "_")
    if self:languageExists(lang) then return lang end

    for _, code in ipairs(self.available_languages) do
        if code:lower() == lang:lower() then return code end
    end

    local prefix = lang:match("^([a-zA-Z]+)")
    if prefix then
        prefix = prefix:lower()
        if self:languageExists(prefix) then return prefix end
        for _, code in ipairs(self.available_languages) do
            if code:lower() == prefix then return code end
        end
    end
    return "en"
end

function Localization:discoverLanguages()
    local lang_dir = self.path .. "/languages"
    self.available_languages = {}
    if not lfs or not lfs.attributes then
        self.available_languages = {
            "ar", "de", "en", "es", "fr", "hu", "id", "it", "ja",
            "ko", "nl", "pl", "pt_br", "ru", "sk", "sr", "tr", "uk", "zh_CN",
        }
        return
    end
    local attr = lfs.attributes(lang_dir)
    if not attr or attr.mode ~= "directory" then
        self.available_languages = {
            "ar", "de", "en", "es", "fr", "hu", "id", "it", "ja",
            "ko", "nl", "pl", "pt_br", "ru", "sk", "sr", "tr", "uk", "zh_CN",
        }
        return
    end
    for file in lfs.dir(lang_dir) do
        local lang_code = file:match("^(.+)%.po$")
        if lang_code then
            table.insert(self.available_languages, lang_code)
        end
    end
    table.sort(self.available_languages)
end

function Localization:loadTranslations()
    local po_file = self.path .. "/languages/" .. self.current_language .. ".po"
    local translations = self:parsePO(po_file)
    if translations then
        self.translations = translations
    else
        if self.current_language ~= "en" then
            self.current_language = "en"
            translations = self:parsePO(self.path .. "/languages/en.po")
            self.translations = translations or {}
        else
            self.translations = {}
        end
    end
end

function Localization:init(path)
    self.path = path and path:gsub("\\", "/") or resolveScriptDir()
    self.initialized = true
    self:discoverLanguages()
    self.current_language = self:detectSystemLanguage()
    self:loadTranslations()
    logger.info("Nimbus Localization initialized:", self.current_language)
end

function Localization:ensureInit(path)
    if not self.initialized then
        self:init(path)
    elseif path then
        local norm_path = path:gsub("\\", "/")
        if norm_path ~= self.path and next(self.translations) == nil then
            self:init(path)
        end
    end
end

function Localization:t(key, ...)
    if key == "Nimbus" then
        return "Nimbus"
    end
    self:ensureInit()
    local translation = self.translations[key]
    if not translation or translation == "" then
        translation = key
    end

    local arg_count = select("#", ...)
    if arg_count > 0 then
        local args = {}
        for i = 1, arg_count do
            local arg = select(i, ...)
            args[i] = (arg == nil) and "???" or arg
        end
        if translation:find("%%%d+%$") then
            local success, result = pcall(function()
                return string.gsub(translation, "%%(%d+)%$([-+ #0]?%d*%.?%d*[cdeEfgGiouuxXsqp%%])", function(index, spec)
                    local idx = tonumber(index)
                    local val = args[idx]
                    if val == nil then val = "???" end
                    if spec == "%" then return "%" end
                    return string.format("%" .. spec, val)
                end)
            end)
            if success then return result end
            return translation
        else
            local success, result = pcall(string.format, translation, (unpack or table.unpack)(args))
            if success then return result end
            return translation
        end
    end

    return translation
end

function Localization:getHelper()
    return function(key, ...)
        return self:t(key, ...)
    end
end

return Localization
