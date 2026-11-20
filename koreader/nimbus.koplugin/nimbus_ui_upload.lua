--[[--
nimbus_ui_upload.lua
Mixin for UILibrary: Upload Current Book, Upload All Unsynced Books,
and paginated Select Books to Upload checklist + batch uploader.
--]]

local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ok_loc, Localization = pcall(require, "localization_nimbus")
local _ = (ok_loc and Localization and Localization.getHelper) and Localization:getHelper() or require("gettext")

local Cloud = require("nimbus_cloud")
local Sync = require("nimbus_sync")
local NimbusProgress = require("nimbus_progress")
local Widgets = require("nimbus_ui_widgets")
local theme = require("nimbus_theme")

local UploadMixin = {}
local sc = theme.sc

function UploadMixin.uploadBookBatch(books_list, open_doc, on_complete)
    if not Cloud.isConfigured() then
        Widgets.showToast(_("Please connect a cloud storage provider in Settings first."), 3)
        if on_complete then on_complete(false, 0) end
        return
    end
    if not books_list or #books_list == 0 then
        Widgets.showToast(_("All device books are already synced to Nimbus Cloud."), 2.5)
        if on_complete then on_complete(false, 0) end
        return
    end

    local total_books = #books_list
    local prog_dlg = NimbusProgress:new{
        title = _("Uploading to Nimbus Cloud"),
        subtitle = _("Preparing upload..."),
        detail = string.format(_("0 of %d books"), total_books),
        progress = 0,
    }
    prog_dlg:show()

    UIManager:nextTick(function()
        local uploaded = 0
        local last_err = nil

        for idx, book in ipairs(books_list) do
            if prog_dlg:isCanceled() then break end
            local filepath = book.local_path or book.filepath
            local title = book.title or (filepath and filepath:match("([^/\\]+)$")) or "Book"
            local base_pct = math.floor(((idx - 1) / total_books) * 100)
            prog_dlg:setProgress(base_pct,
                string.format(_("Uploading %d of %d..."), idx, total_books),
                title)

            local props = book.props or {
                title = book.title,
                authors = book.authors,
                series = book.series,
                series_index = book.series_index,
                language = book.language,
                isbn = book.isbn,
                partial_md5 = book.partial_md5,
            }

            local ok_up, res_or_err = false, nil
            Sync.uploadBook(filepath, props, nil, function(ok, res)
                ok_up = ok
                res_or_err = res
            end, {
                open_doc = open_doc,
                is_canceled = function() return prog_dlg:isCanceled() end,
                on_progress = function(sent, total_b, phase)
                    local file_frac = (total_b and total_b > 0) and (sent / total_b) or 0
                    local overall_pct = math.floor((((idx - 1) + file_frac) / total_books) * 100)
                    local sub = (phase == "finalizing")
                        and string.format(_("Finalizing %d of %d..."), idx, total_books)
                        or string.format("%d/%d · %s/%s", idx, total_books,
                            NimbusProgress.formatBytes(sent), NimbusProgress.formatBytes(total_b))
                    prog_dlg:setProgress(overall_pct, sub, title)
                end,
            })

            if ok_up then
                uploaded = uploaded + 1
            else
                last_err = res_or_err
                if res_or_err == "canceled" then break end
            end
        end

        prog_dlg:close()
        local toast_msg
        if prog_dlg:isCanceled() then
            toast_msg = string.format(_("Upload canceled (%d uploaded)."), uploaded)
        elseif uploaded > 0 then
            toast_msg = string.format(_("Uploaded %d of %d book(s) to Nimbus Cloud!"), uploaded, total_books)
        else
            toast_msg = _("Upload failed: ") .. tostring(last_err or _("Unknown error"))
        end

        if on_complete then
            on_complete(uploaded > 0, uploaded, toast_msg)
        else
            Widgets.showToast(toast_msg, 3)
        end
    end)
end

function UploadMixin.showBookSelectionChecklist(device_books, open_doc, on_complete)
    local selected = {}
    for _, b in ipairs(device_books) do
        if not b.is_in_cloud then
            selected[b.local_path] = true
        end
    end

    local page = 1
    local per_page = 6
    local total_pages = math.max(1, math.ceil(#device_books / per_page))

    local renderChecklist
    renderChecklist = function()
        local selected_count = 0
        local list_to_upload = {}
        for _, b in ipairs(device_books) do
            if selected[b.local_path] then
                selected_count = selected_count + 1
                table.insert(list_to_upload, b)
            end
        end

        Widgets.showCardDialog{
            title = _("Select Books to Upload"),
            body_widget = function(inner_w, closeDlg)
                local vg = VerticalGroup:new{ align = "left" }

                local bulk_row = HorizontalGroup:new{
                    Widgets.createButton{
                        text = _("Unsynced"),
                        text_font_size = 14,
                        padding = sc(3),
                        padding_h = sc(8),
                        callback = function()
                            closeDlg()
                            for _, b in ipairs(device_books) do
                                selected[b.local_path] = not b.is_in_cloud
                            end
                            renderChecklist()
                        end,
                    },
                    HorizontalSpan:new{ width = sc(6) },
                    Widgets.createButton{
                        text = _("Select All"),
                        text_font_size = 14,
                        padding = sc(3),
                        padding_h = sc(8),
                        callback = function()
                            closeDlg()
                            for _, b in ipairs(device_books) do
                                selected[b.local_path] = true
                            end
                            renderChecklist()
                        end,
                    },
                    HorizontalSpan:new{ width = sc(6) },
                    Widgets.createButton{
                        text = _("None"),
                        text_font_size = 14,
                        padding = sc(3),
                        padding_h = sc(8),
                        callback = function()
                            closeDlg()
                            selected = {}
                            renderChecklist()
                        end,
                    },
                }
                table.insert(vg, bulk_row)
                table.insert(vg, VerticalSpan:new{ width = sc(8) })

                local start_i = (page - 1) * per_page + 1
                local end_i = math.min(#device_books, start_i + per_page - 1)
                for i = start_i, end_i do
                    local b = device_books[i]
                    local sub = b.is_in_cloud and _("Already in Cloud") or _("Local Only")
                    if b.authors and b.authors ~= "" then
                        sub = tostring(b.authors) .. " · " .. sub
                    end
                    table.insert(vg, Widgets.createCheckboxRow(b.title, sub, selected[b.local_path] == true, inner_w, function()
                        closeDlg()
                        selected[b.local_path] = not (selected[b.local_path] == true)
                        renderChecklist()
                    end))
                end

                if total_pages > 1 then
                    table.insert(vg, VerticalSpan:new{ width = sc(8) })
                    table.insert(vg, HorizontalGroup:new{
                        Widgets.createButton{
                            text = _("‹ Prev"),
                            text_font_size = 14,
                            padding = sc(3),
                            padding_h = sc(8),
                            callback = function()
                                if page > 1 then
                                    closeDlg()
                                    page = page - 1
                                    renderChecklist()
                                end
                            end,
                        },
                        HorizontalSpan:new{ width = sc(10) },
                        TextWidget:new{
                            text = string.format("%d / %d", page, total_pages),
                            face = Font:getFace("cfont", 14),
                            fgcolor = theme.color_label_dim,
                        },
                        HorizontalSpan:new{ width = sc(10) },
                        Widgets.createButton{
                            text = _("Next ›"),
                            text_font_size = 14,
                            padding = sc(3),
                            padding_h = sc(8),
                            callback = function()
                                if page < total_pages then
                                    closeDlg()
                                    page = page + 1
                                    renderChecklist()
                                end
                            end,
                        },
                    })
                end

                return vg
            end,
            buttons = {
                {
                    text = string.format(_("Upload (%d)"), selected_count),
                    is_primary = true,
                    callback = function()
                        UploadMixin.uploadBookBatch(list_to_upload, open_doc, on_complete)
                    end,
                },
                { text = _("Cancel") },
            },
        }
    end

    renderChecklist()
end

function UploadMixin.showUploadDialog(device_books, open_doc_info, on_complete)
    local unsynced = {}
    for _, b in ipairs(device_books or {}) do
        if not b.is_in_cloud then
            table.insert(unsynced, b)
        end
    end

    Widgets.showCardDialog{
        title = _("Upload to Nimbus"),
        body_widget = function(inner_w, closeDlg)
            local vg = VerticalGroup:new{ align = "left" }

            if open_doc_info and open_doc_info.filepath then
                local title = (open_doc_info.props and open_doc_info.props.title)
                    or open_doc_info.filepath:match("([^/\\]+)$") or _("Current Book")
                table.insert(vg, Widgets.createSettingRow(_("Upload Current Book"),
                    TextWidget:new{ text = "›", face = Font:getFace("cfont", 18) }, inner_w, function()
                        closeDlg()
                        UploadMixin.uploadBookBatch({ {
                            local_path = open_doc_info.filepath,
                            title = title,
                            props = open_doc_info.props,
                        } }, open_doc_info.open_doc, on_complete)
                    end))
            end

            local unsynced_label = (#unsynced > 0)
                and string.format(_("Upload All Unsynced Books (%d)"), #unsynced)
                or _("Upload All Unsynced Books (0 · All Synced)")
            table.insert(vg, Widgets.createSettingRow(
                unsynced_label,
                TextWidget:new{ text = "›", face = Font:getFace("cfont", 18) }, inner_w, function()
                    closeDlg()
                    UploadMixin.uploadBookBatch(unsynced, open_doc_info and open_doc_info.open_doc, on_complete)
                end))

            table.insert(vg, Widgets.createSettingRow(
                string.format(_("Select Books to Upload... (%d on device)"), #(device_books or {})),
                TextWidget:new{ text = "›", face = Font:getFace("cfont", 18) }, inner_w, function()
                    closeDlg()
                    UploadMixin.showBookSelectionChecklist(device_books or {}, open_doc_info and open_doc_info.open_doc, on_complete)
                end))

            return vg
        end,
        buttons = {
            { text = _("Cancel") },
        },
    }
end

return UploadMixin
