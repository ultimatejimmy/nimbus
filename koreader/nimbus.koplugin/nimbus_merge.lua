--[[--
nimbus_merge.lua
Pure functional deterministic merge engine matching spec/SCHEMA.md.
--]]

local Merge = {}

local function isBetterProgress(candidate, current, candidate_dev, current_dev)
    if not current then return true end
    local c_ts = tonumber(candidate.updated_at) or 0
    local cur_ts = tonumber(current.updated_at) or 0
    if c_ts ~= cur_ts then
        return c_ts > cur_ts
    end
    local c_pct = tonumber(candidate.percent) or 0
    local cur_pct = tonumber(current.percent) or 0
    if c_pct ~= cur_pct then
        return c_pct > cur_pct
    end
    return tostring(candidate_dev or "") > tostring(current_dev or "")
end

--- Merges progress shards: array of { device_id, books = { [book_id] = record } }
-- @return table { [book_id] = winning_record_with_device_id }
function Merge.mergeProgress(device_shards)
    local merged = {}
    for _, shard in ipairs(device_shards or {}) do
        local dev_id = shard.device_id or ""
        local books = shard.books or {}
        for book_id, rec in pairs(books) do
            if type(rec) == "table" then
                local cur = merged[book_id]
                if isBetterProgress(rec, cur, dev_id, cur and cur.device_id) then
                    local copy = {}
                    for k, v in pairs(rec) do copy[k] = v end
                    copy.book_id = copy.book_id or book_id
                    copy.device_id = dev_id
                    merged[book_id] = copy
                end
            end
        end
    end
    return merged
end

local function isBetterAnnotation(candidate, current, candidate_dev, current_dev)
    if not current then return true end
    local c_ts = tonumber(candidate.updated_at) or 0
    local cur_ts = tonumber(current.updated_at) or 0
    if c_ts ~= cur_ts then
        return c_ts > cur_ts
    end
    local c_del = candidate.deleted == true
    local cur_del = current.deleted == true
    if c_del ~= cur_del then
        return c_del
    end
    local c_note = (candidate.note and candidate.note ~= "") and 1 or 0
    local cur_note = (current.note and current.note ~= "") and 1 or 0
    if c_note ~= cur_note then
        return c_note > cur_note
    end
    return tostring(candidate_dev or "") > tostring(current_dev or "")
end

--- Merges annotation shards: array of { device_id, books = { [book_id] = Annotation[] } }
-- @return table { [book_id] = { all = Annotation[], active = Annotation[] } }
function Merge.mergeAnnotations(device_shards)
    local by_book = {}
    for _, shard in ipairs(device_shards or {}) do
        local dev_id = shard.device_id or ""
        local books = shard.books or {}
        for book_id, list in pairs(books) do
            if type(list) == "table" then
                by_book[book_id] = by_book[book_id] or {}
                local map = by_book[book_id]
                for _, ann in ipairs(list) do
                    if type(ann) == "table" and ann.id then
                        local cur = map[ann.id]
                        if isBetterAnnotation(ann, cur, dev_id, cur and cur._device_id) then
                            local copy = {}
                            for k, v in pairs(ann) do copy[k] = v end
                            copy._device_id = dev_id
                            map[ann.id] = copy
                        end
                    end
                end
            end
        end
    end

    local result = {}
    for book_id, map in pairs(by_book) do
        local all_list = {}
        local active_list = {}
        for _, ann in pairs(map) do
            ann._device_id = nil
            table.insert(all_list, ann)
            if not ann.deleted then
                table.insert(active_list, ann)
            end
        end
        local function sortFn(a, b)
            local pa = tonumber(a.percent) or 0
            local pb = tonumber(b.percent) or 0
            if pa ~= pb then return pa < pb end
            local ca = tonumber(a.created_at) or 0
            local cb = tonumber(b.created_at) or 0
            if ca ~= cb then return ca < cb end
            return tostring(a.id) < tostring(b.id)
        end
        table.sort(all_list, sortFn)
        table.sort(active_list, sortFn)
        result[book_id] = {
            all = all_list,
            active = active_list,
        }
    end
    return result
end

--- Merges session shards: array of { device_id, month, sessions = Session[] }
-- @return Session[] (with device_id attached)
function Merge.mergeSessions(session_shards)
    local dedup = {}
    for _, shard in ipairs(session_shards or {}) do
        local dev_id = shard.device_id or ""
        for _, s in ipairs(shard.sessions or {}) do
            if type(s) == "table" and s.book_id and s.start_time then
                local key = dev_id .. "|" .. tostring(s.book_id) .. "|" .. tostring(s.start_time)
                local cur = dedup[key]
                local replace = false
                if not cur then
                    replace = true
                elseif (tonumber(s.duration_sec) or 0) > (tonumber(cur.duration_sec) or 0) then
                    replace = true
                elseif (tonumber(s.duration_sec) or 0) == (tonumber(cur.duration_sec) or 0)
                    and (tonumber(s.pages_read) or 0) > (tonumber(cur.pages_read) or 0) then
                    replace = true
                end
                if replace then
                    local copy = {}
                    for k, v in pairs(s) do copy[k] = v end
                    copy.device_id = dev_id
                    dedup[key] = copy
                end
            end
        end
    end

    local list = {}
    for _, s in pairs(dedup) do
        table.insert(list, s)
    end
    table.sort(list, function(a, b)
        if a.start_time ~= b.start_time then
            return a.start_time < b.start_time
        end
        if a.book_id ~= b.book_id then
            return tostring(a.book_id) < tostring(b.book_id)
        end
        return tostring(a.device_id) < tostring(b.device_id)
    end)
    return list
end

return Merge
