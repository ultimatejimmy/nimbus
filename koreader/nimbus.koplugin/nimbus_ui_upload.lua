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
local Settings = require("nimbus_settings")
local Sync = require("nimbus_sync")
local NimbusProgress = require("nimbus_progress")
local Widgets = require("nimbus_ui_widgets")
local theme = require("nimbus_theme")

local UploadMixin = {}
local sc = theme.sc

function UploadMixin.getActiveJob()
    return NimbusProgress.getActiveJob()
end

function UploadMixin.setStatusListener(fn)
    NimbusProgress.setStatusListener(fn)
end

local function notifyUploadStatus(is_progress_only)
    NimbusProgress.notifyStatus(is_progress_only)
end

function UploadMixin.uploadBookBatch(books_list, _open_doc, on_complete)
    local existing_job = NimbusProgress.getActiveJob()
    if existing_job then
        if existing_job.reopen then existing_job.reopen() end
        return
    end
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
    local active_cancel_fn = nil
    local is_canceled = false
    local finished = false
    local uploaded = 0
    local last_err = nil
    local batch_catalog = nil
    local dirty_catalog = false
    local since_last_save = 0

    local prog_dlg
    local job = {
        kind = "upload",
        current = 1,
        total = total_books,
        uploaded = 0,
        pct = 0,
        subtitle = _("Preparing upload..."),
        detail = string.format(_("0 of %d books"), total_books),
        is_background = false,
    }
    NimbusProgress.setActiveJob(job)

    local function closeAndFinish(is_canceled_flag)
        if prog_dlg and not prog_dlg.is_closed then
            prog_dlg:close()
        end
        NimbusProgress.clearActiveJob(job)

        local toast_msg
        if is_canceled_flag then
            toast_msg = string.format(_("Upload canceled (%d uploaded)."), uploaded)
        elseif uploaded > 0 then
            toast_msg = string.format(_("Uploaded %d of %d book(s) to Nimbus Cloud!"), uploaded, total_books)
        else
            toast_msg = _("Upload failed: ") .. tostring(last_err or _("Unknown error"))
        end

        if on_complete then
            on_complete(uploaded > 0, uploaded, toast_msg, job.is_background)
        else
            Widgets.showToast(toast_msg, 3)
        end
    end

    local function finalizeBatch(is_canceled_flag)
        if finished then return end
        finished = true
        if active_cancel_fn then
            local cancel_sub = active_cancel_fn
            active_cancel_fn = nil
            pcall(cancel_sub)
        end

        if dirty_catalog and batch_catalog then
            Sync.runInBackground(function()
                local ok_save, save_err = false, nil
                Sync.saveCatalog(batch_catalog, function(ok_s, err_s)
                    ok_save = ok_s
                    save_err = err_s
                end)
                if ok_save then
                    local _cat, merged = Sync.loadCachedCatalog()
                    Sync.saveCachedCatalog(batch_catalog, merged)
                end
                return { ok = ok_save, err = save_err }
            end, function(ok_bg, res)
                if (not ok_bg or (type(res) == "table" and not res.ok)) and not last_err then
                    last_err = (type(res) == "table" and res.err) or res
                end
                closeAndFinish(is_canceled_flag)
            end, { user_initiated = true, priority = "interactive_bg" })
        else
            if uploaded > 0 and batch_catalog then
                local _cat, merged = Sync.loadCachedCatalog()
                Sync.saveCachedCatalog(batch_catalog, merged)
            end
            closeAndFinish(is_canceled_flag)
        end
    end

    local function openProgressDialog()
        if finished then return end
        if prog_dlg and not prog_dlg.is_closed then return end
        job.is_background = false
        prog_dlg = NimbusProgress:new{
            title = _("Uploading to Nimbus Cloud"),
            subtitle = job.subtitle,
            detail = job.detail,
            progress = job.pct,
            background_text = _("Background"),
            on_background = function()
                if finished then return end
                job.is_background = true
                notifyUploadStatus()
                Widgets.showToast(string.format(_("Uploading %d book(s) in background..."), math.max(1, total_books - uploaded)), 2.5)
            end,
            on_cancel = function()
                is_canceled = true
                finalizeBatch(true)
            end,
        }
        prog_dlg:show()
        notifyUploadStatus()
    end

    job.reopen = openProgressDialog
    job.cancel = function()
        is_canceled = true
        finalizeBatch(true)
    end

    openProgressDialog()

    local function updateJobProgress(pct, subtitle, detail)
        job.pct = pct
        job.subtitle = subtitle
        job.detail = detail
        if prog_dlg and not prog_dlg.is_closed then
            prog_dlg:setProgress(pct, subtitle, detail)
        end
        if job.is_background then
            notifyUploadStatus(true)
        end
    end

    local function uploadNext(idx)
        if finished or is_canceled then
            finalizeBatch(true)
            return
        end
        if idx > total_books then
            finalizeBatch(false)
            return
        end

        local book = books_list[idx]
        local filepath = book.local_path or book.filepath
        local title = book.title or (filepath and filepath:match("([^/\\]+)$")) or _("Book")
        local base_pct = math.floor(((idx - 1) / total_books) * 100)
        job.current = idx
        updateJobProgress(base_pct, string.format(_("Uploading %d of %d..."), idx, total_books), title)

        local props = book.props or {
            title = book.title,
            authors = book.authors,
            series = book.series,
            series_index = book.series_index,
            language = book.language,
            isbn = book.isbn,
            partial_md5 = book.partial_md5,
        }

        local _started, cancel_fn = Sync.runInBackground(function(report_progress)
            local ok_up, res_or_err = false, nil
            Sync.uploadBook(filepath, props, nil, function(ok, res)
                ok_up = ok
                res_or_err = res
            end, {
                catalog = batch_catalog,
                defer_catalog_save = true,
                skip_metadata_file = true,
                on_progress = function(sent, total, phase)
                    if report_progress then
                        local book_frac = (total and total > 0) and (sent / total) or 0
                        local overall_pct = math.floor((((idx - 1) + book_frac) / total_books) * 100)
                        local sub = (phase == "finalizing")
                            and string.format(_("Finalizing %d of %d..."), idx, total_books)
                            or string.format(_("Uploading %d of %d (%d%%)..."), idx, total_books, math.floor(book_frac * 100))
                        report_progress(overall_pct, sub, title)
                    end
                end,
            })
            return {
                ok = ok_up,
                entry = ok_up and res_or_err or nil,
                err = (not ok_up) and tostring(res_or_err or _("Unknown error")) or nil,
            }
        end, function(ok_bg, res)
            active_cancel_fn = nil
            if finished or is_canceled then return end

            if ok_bg and type(res) == "table" and res.ok and type(res.entry) == "table" then
                batch_catalog.books = batch_catalog.books or {}
                batch_catalog.books[res.entry.id] = res.entry
                Settings.linkBook(filepath, res.entry.id)
                uploaded = uploaded + 1
                job.uploaded = uploaded
                dirty_catalog = true
                since_last_save = since_last_save + 1
                local done_pct = math.floor((idx / total_books) * 100)
                updateJobProgress(done_pct, string.format(_("Uploading %d of %d..."), idx, total_books), title)

                if since_last_save >= 10 then
                    local _s, c_fn = Sync.runInBackground(function()
                        local ok_save = false
                        Sync.saveCatalog(batch_catalog, function(ok_s)
                            ok_save = ok_s
                        end)
                        return ok_save
                    end, function(ok_s_bg, saved_res)
                        active_cancel_fn = nil
                        if finished or is_canceled then return end
                        if ok_s_bg and saved_res then
                            since_last_save = 0
                            dirty_catalog = false
                        end
                        uploadNext(idx + 1)
                    end, { user_initiated = true, priority = "interactive_bg" })
                    active_cancel_fn = c_fn
                else
                    uploadNext(idx + 1)
                end
            else
                last_err = (type(res) == "table" and res.err) or res
                if last_err == "canceled" then
                    finalizeBatch(true)
                else
                    uploadNext(idx + 1)
                end
            end
        end, {
            user_initiated = true,
            priority = "interactive_bg",
            on_progress = function(pct, sub, det)
                if not finished and not is_canceled and pct then
                    updateJobProgress(pct, sub or job.subtitle, det or job.detail)
                end
            end,
        })
        active_cancel_fn = cancel_fn
    end

    UIManager:nextTick(function()
        if finished or is_canceled then return end
        local _started, cancel_fn = Sync.runInBackground(function()
            local ok_cat, cat_or_err = false, nil
            Sync.loadCatalog(function(ok, res)
                ok_cat = ok
                cat_or_err = res
            end)
            return {
                ok = ok_cat,
                err = (not ok_cat) and tostring(cat_or_err or _("Unknown error")) or nil,
            }
        end, function(ok_bg, res)
            active_cancel_fn = nil
            if finished or is_canceled then return end
            if not ok_bg or type(res) ~= "table" or not res.ok then
                last_err = (type(res) == "table" and res.err) or res
                finalizeBatch(false)
                return
            end
            batch_catalog = Sync.loadCachedCatalog() or { books = {} }
            uploadNext(1)
        end, { user_initiated = true, priority = "interactive_bg" })
        active_cancel_fn = cancel_fn
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
    local existing_job = NimbusProgress.getActiveJob()
    if existing_job then
        if existing_job.reopen then existing_job.reopen() end
        return
    end
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
