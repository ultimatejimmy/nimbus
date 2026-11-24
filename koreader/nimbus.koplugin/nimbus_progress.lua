--[[--
nimbus_progress.lua
Unified, cancelable progress dialog for Nimbus upload/download/sync operations
(adapted from backup_progress.lua).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ok_hg, HorizontalGroup = pcall(require, "ui/widget/horizontalgroup")
if not ok_hg or not HorizontalGroup then HorizontalGroup = nil end
local ok_hs, HorizontalSpan = pcall(require, "ui/widget/horizontalspan")
if not ok_hs or not HorizontalSpan then HorizontalSpan = nil end
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local ok_loc, Localization = pcall(require, "localization_nimbus")
local _ = (ok_loc and Localization and Localization.getHelper) and Localization:getHelper() or require("gettext")

local ok_bt, ButtonTable = pcall(require, "ui/widget/buttontable")
if not ok_bt or not ButtonTable then ButtonTable = nil end

local ok_btn, Button = pcall(require, "ui/widget/button")
if not ok_btn or not Button then Button = nil end

local ok_pw, ProgressWidget = pcall(require, "ui/widget/progresswidget")
if not ok_pw or not ProgressWidget then ProgressWidget = nil end

local ok_size, Size = pcall(require, "ui/size")
if not ok_size or not Size then
    Size = {
        line = { thin = 1, medium = 2 },
        padding = { default = 10, large = 15 },
        margin = { tiny = 2, default = 10 },
        radius = { window = 0 },
        border = { window = 2 },
    }
end

local ok_time, time = pcall(require, "ui/time")
if not ok_time or not time then time = nil end

local function sc(n)
    if Device and Device.screen and Device.screen.scaleBySize then
        return Device.screen:scaleBySize(n)
    end
    return n
end

local NimbusProgress
if InputContainer and type(InputContainer.extend) == "function" then
    NimbusProgress = InputContainer:extend{
        align = "center",
        vertical_align = "center",
        modal = true,
        title = nil,
        subtitle = nil,
        detail = nil,
        progress = 0,
        cancel_text = nil,
        on_cancel = nil,
        background_text = nil,
        on_background = nil,
        cancelable = true,
        is_closed = false,
        is_canceled = false,
    }
else
    NimbusProgress = {
        align = "center",
        vertical_align = "center",
        modal = true,
        is_closed = false,
        is_canceled = false,
    }
    NimbusProgress.__index = NimbusProgress
    function NimbusProgress:new(opts)
        local o = setmetatable(opts or {}, NimbusProgress)
        o:init()
        return o
    end
end

function NimbusProgress:init()
    if InputContainer and InputContainer.init then
        pcall(InputContainer.init, self)
    end
    local Screen = Device and Device.screen
    local screen_w = (Screen and Screen.getWidth and Screen:getWidth()) or 600
    local screen_h = (Screen and Screen.getHeight and Screen:getHeight()) or 800
    self.dimen = (Screen and Screen.getSize and Screen:getSize()) or { w = screen_w, h = screen_h }

    self.dialog_width = self.width or math.min(screen_w - sc(40), sc(420))
    local inner_width = self.dialog_width - sc(32)

    self.title = self.title or _("Operation in Progress")
    self.subtitle = self.subtitle or _("Please wait...")
    self.detail = self.detail or ""
    self.cancel_text = self.cancel_text or _("Cancel")
    self.background_text = self.background_text or _("Background")
    self.cancelable = (self.cancelable ~= false)
    self.progress = self.progress or 0
    self.is_closed = false
    self.is_canceled = false
    self.redraw_interval_ms = self.redraw_interval_ms or 1200
    self.last_redraw_time_ms = 0
    self._applied_progress = nil
    self._applied_subtitle = nil
    self._applied_detail = nil
    self._pending_dirty = false

    if TextWidget then
        self.title_widget = TextWidget:new{
            text = self.title,
            face = Font and Font.getFace and Font:getFace("tfont", 20),
            bold = true,
            max_width = inner_width,
        }
        self.subtitle_widget = TextWidget:new{
            text = self.subtitle,
            face = Font and Font.getFace and Font:getFace("cfont", 15),
            max_width = inner_width,
            fgcolor = Blitbuffer and Blitbuffer.COLOR_BLACK,
        }
        self.detail_widget = TextWidget:new{
            text = self.detail,
            face = Font and Font.getFace and Font:getFace("cfont", 13),
            max_width = inner_width,
            fgcolor = Blitbuffer and Blitbuffer.COLOR_BLACK,
            truncate_with_ellipsis = true,
            truncate_left = true,
        }
    end

    if ProgressWidget then
        local p_val = math.max(0, math.min(1, (self.progress or 0) / 100))
        self.pbar_widget = ProgressWidget:new{
            fillcolor = Blitbuffer and Blitbuffer.COLOR_BLACK,
            width = inner_width,
            height = sc(14),
            padding = (Size and Size.padding and Size.padding.large) or sc(4),
            margin = (Size and Size.margin and Size.margin.tiny) or 0,
            percentage = p_val,
        }
    end

    local has_bg = (type(self.on_background) == "function") and HorizontalGroup and HorizontalSpan
    if Button then
        local function makeActionBtn(label, w, cb, is_enabled)
            local btn = Button:new{
                text = label,
                text_font_size = 16,
                text_font_bold = true,
                bold = true,
                bordersize = sc(1),
                radius = sc(4),
                padding = sc(6),
                padding_h = sc(10),
                width = w,
                enabled = (is_enabled ~= false),
                show_parent = self,
                callback = cb,
            }
            if btn.frame and Blitbuffer then
                btn.frame.color = Blitbuffer.COLOR_BLACK
                btn.frame.bordersize = sc(1)
                btn.frame.background = Blitbuffer.COLOR_WHITE
            end
            return btn
        end

        if has_bg then
            local gap = sc(8)
            local w1 = math.floor((inner_width - gap) / 2)
            local w2 = inner_width - gap - w1
            self.cancel_button = makeActionBtn(self.cancel_text, w1, function()
                self:triggerCancel()
            end, self.cancelable)
            self.bg_button = makeActionBtn(self.background_text, w2, function()
                self:triggerBackground()
            end, true)
        else
            self.cancel_button = makeActionBtn(self.cancel_text, inner_width, function()
                self:triggerCancel()
            end, self.cancelable)
        end
    elseif ButtonTable then
        local row = {
            {
                text = self.cancel_text,
                id = "cancel",
                enabled = self.cancelable,
                callback = function()
                    self:triggerCancel()
                end,
            },
        }
        if type(self.on_background) == "function" then
            table.insert(row, {
                text = self.background_text,
                id = "background",
                callback = function()
                    self:triggerBackground()
                end,
            })
        end
        self.button_table = ButtonTable:new{
            width = inner_width,
            buttons = { row },
            zero_sep = true,
            show_parent = self,
        }
    end

    local ok_lw, LineWidget = pcall(require, "ui/widget/linewidget")
    local ok_gm, Geom = pcall(require, "ui/geometry")
    local group_items = {}
    if self.title_widget then
        local title_item = self.title_widget
        if CenterContainer and self.title_widget.getSize then
            local t_size = self.title_widget:getSize()
            title_item = CenterContainer:new{
                dimen = { w = inner_width, h = (t_size and t_size.h) or sc(22) },
                self.title_widget,
            }
        end
        table.insert(group_items, title_item)
        if VerticalSpan then table.insert(group_items, VerticalSpan:new{ width = sc(8) }) end
        if ok_lw and LineWidget and ok_gm and Geom and Blitbuffer then
            table.insert(group_items, LineWidget:new{
                dimen = Geom:new{ w = inner_width, h = sc(1) },
                background = Blitbuffer.COLOR_BLACK,
            })
            if VerticalSpan then table.insert(group_items, VerticalSpan:new{ width = sc(10) }) end
        end
    end
    if self.subtitle_widget then
        local sub_item = self.subtitle_widget
        if CenterContainer and self.subtitle_widget.getSize then
            local s_size = self.subtitle_widget:getSize()
            self.subtitle_container = CenterContainer:new{
                dimen = { w = inner_width, h = (s_size and s_size.h) or sc(16) },
                self.subtitle_widget,
            }
            sub_item = self.subtitle_container
        end
        table.insert(group_items, sub_item)
        if VerticalSpan then table.insert(group_items, VerticalSpan:new{ width = sc(4) }) end
    end
    if self.detail_widget then
        local det_item = self.detail_widget
        if CenterContainer and self.detail_widget.getSize then
            local d_size = self.detail_widget:getSize()
            self.detail_container = CenterContainer:new{
                dimen = { w = inner_width, h = (d_size and d_size.h) or sc(14) },
                self.detail_widget,
            }
            det_item = self.detail_container
        end
        table.insert(group_items, det_item)
        if VerticalSpan then table.insert(group_items, VerticalSpan:new{ width = sc(12) }) end
    end
    if self.pbar_widget then
        table.insert(group_items, self.pbar_widget)
        if VerticalSpan then table.insert(group_items, VerticalSpan:new{ width = sc(14) }) end
    end
    if self.cancel_button and self.bg_button and HorizontalGroup and HorizontalSpan then
        table.insert(group_items, HorizontalGroup:new{
            self.cancel_button,
            HorizontalSpan:new{ width = sc(8) },
            self.bg_button,
        })
    elseif self.cancel_button then
        table.insert(group_items, self.cancel_button)
    elseif self.button_table then
        table.insert(group_items, self.button_table)
    end

    if VerticalGroup then
        group_items.align = "center"
        self.content_group = VerticalGroup:new(group_items)
    else
        self.content_group = group_items
    end

    if FrameContainer then
        self.frame = FrameContainer:new{
            width = self.dialog_width,
            padding = sc(14),
            margin = 0,
            bordersize = sc(2),
            color = Blitbuffer and Blitbuffer.COLOR_BLACK,
            radius = sc(4),
            background = (Blitbuffer and Blitbuffer.COLOR_WHITE),
            self.content_group,
        }
        if CenterContainer then
            self[1] = CenterContainer:new{
                dimen = self.dimen,
                self.frame,
            }
        else
            self[1] = self.frame
        end
    end
end

function NimbusProgress:getNowMs()
    if time and time.now then
        return math.floor(time.to_ms(time.now()))
    end
    return os.time() * 1000
end

function NimbusProgress:show()
    if self.is_closed then return end
    local ok_w, W = pcall(require, "nimbus_ui_widgets")
    if ok_w and W and W.closeToast then
        pcall(W.closeToast)
    end
    if UIManager and UIManager.show then
        UIManager:show(self)
        if UIManager.forceRePaint then
            pcall(function() UIManager:forceRePaint() end)
        end
    end
end

function NimbusProgress:close()
    if self.is_closed then return end
    self.is_closed = true
    if UIManager and UIManager.close then
        pcall(function() UIManager:close(self) end)
    end
    if UIManager and UIManager.setDirty then
        pcall(function() UIManager:setDirty("all", "ui") end)
    end
end

function NimbusProgress:isCanceled()
    return self.is_canceled == true
end

function NimbusProgress:triggerCancel()
    if not self.cancelable or self.is_canceled then return end
    self.is_canceled = true
    self:setSubtitle(_("Canceling..."))
    if self.on_cancel then
        pcall(self.on_cancel, self)
    end
end

function NimbusProgress:triggerBackground()
    if self.is_closed then return end
    self:close()
    if self.on_background then
        pcall(self.on_background, self)
    end
end

function NimbusProgress:onCloseWidget()
    self.is_closed = true
end

function NimbusProgress:onBack()
    if self.cancelable then
        self:triggerCancel()
    end
    return true
end

function NimbusProgress:_applyUpdates(force)
    if self.is_closed then return end
    local changed = false
    if self.pbar_widget and self._applied_progress ~= self.progress then
        self._applied_progress = self.progress
        self.pbar_widget:setPercentage(math.max(0, math.min(1, self.progress / 100)))
        changed = true
    end
    if self.subtitle_widget and self._applied_subtitle ~= self.subtitle then
        self._applied_subtitle = self.subtitle
        self.subtitle_widget:setText(self.subtitle)
        changed = true
    end
    if self.detail_widget and self._applied_detail ~= self.detail then
        self._applied_detail = self.detail
        self.detail_widget:setText(self.detail)
        changed = true
    end
    if changed or force then
        if UIManager and UIManager.setDirty then
            pcall(function() UIManager:setDirty(self, "ui") end)
        end
        if UIManager and UIManager.forceRePaint then
            pcall(function() UIManager:forceRePaint() end)
        end
        self.last_redraw_time_ms = self:getNowMs()
    end
end

function NimbusProgress:setProgress(percent, subtitle, detail)
    self.progress = math.max(0, math.min(100, tonumber(percent) or 0))
    if subtitle ~= nil then self.subtitle = subtitle end
    if detail ~= nil then self.detail = detail end
    local now = self:getNowMs()
    if (now - self.last_redraw_time_ms) >= self.redraw_interval_ms or self.progress >= 100 then
        self:_applyUpdates(true)
    end
end

function NimbusProgress:setSubtitle(subtitle)
    self.subtitle = subtitle or ""
    self:_applyUpdates(true)
end

function NimbusProgress:setDetail(detail)
    self.detail = detail or ""
    self:_applyUpdates(true)
end

NimbusProgress._active_job = nil
NimbusProgress._status_listener = nil

function NimbusProgress.setActiveJob(job)
    NimbusProgress._active_job = job
    NimbusProgress.notifyStatus(false)
end

function NimbusProgress.getActiveJob()
    return NimbusProgress._active_job
end

function NimbusProgress.clearActiveJob(job)
    if job == nil or NimbusProgress._active_job == job then
        NimbusProgress._active_job = nil
        NimbusProgress.notifyStatus(false)
    end
end

function NimbusProgress.setStatusListener(fn)
    NimbusProgress._status_listener = fn
end

function NimbusProgress.notifyStatus(is_progress_only)
    if type(NimbusProgress._status_listener) == "function" then
        pcall(NimbusProgress._status_listener, is_progress_only == true)
    end
end

function NimbusProgress.formatBytes(bytes)
    local b = tonumber(bytes) or 0
    if b >= 1024 * 1024 then
        return string.format("%.1f MB", b / (1024 * 1024))
    elseif b >= 1024 then
        return string.format("%.0f KB", b / 1024)
    end
    return string.format("%d B", b)
end

return NimbusProgress
