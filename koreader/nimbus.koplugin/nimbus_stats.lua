--[[--
nimbus_stats.lua
Reads KOReader's settings/statistics.sqlite3 and aggregates page_stat_data into
monthly Nimbus reading sessions (sessions/YYYY-MM.json), plus optional safe import.
--]]

local ok_ds, DataStorage = pcall(require, "datastorage")
local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")

local Stats = {}

local SESSION_GAP_SEC = 300 -- 5 minutes gap starts a new reading session

local function getStatsDbPath()
    local base = (ok_ds and DataStorage and DataStorage.getDataDir and DataStorage:getDataDir()) or "."
    return base .. "/settings/statistics.sqlite3"
end

--- Aggregates sorted page_stat_data rows into reading sessions.
-- @param rows table[] array of { md5, start_time, duration, page, total_pages }
-- @param md5_to_book_id table { [partial_md5] = book_id }
-- @return table { [YYYY-MM] = Session[] }
function Stats.aggregateRows(rows, md5_to_book_id)
    local by_month = {}
    local current = nil

    local function flushCurrent()
        if not current then return end
        local month = os.date("!%Y-%m", current.start_time)
        by_month[month] = by_month[month] or {}
        table.insert(by_month[month], {
            book_id = current.book_id,
            partial_md5 = current.partial_md5,
            start_time = current.start_time,
            duration_sec = math.max(1, current.duration_sec),
            pages_read = math.max(1, current.pages_read),
            start_percent = current.start_percent,
            end_percent = current.end_percent,
        })
        current = nil
    end

    for _, r in ipairs(rows or {}) do
        local book_id = (md5_to_book_id and md5_to_book_id[r.md5]) or nil
        if book_id and r.start_time then
            local ts = tonumber(r.start_time) or 0
            local dur = tonumber(r.duration) or 0
            local page = tonumber(r.page) or 0
            local total = tonumber(r.total_pages) or 0
            local pct = (total > 0) and math.min(1, math.max(0, page / total)) or 0

            if current
                and current.book_id == book_id
                and (ts - current.last_end_time) <= SESSION_GAP_SEC then
                current.duration_sec = current.duration_sec + dur
                current.last_end_time = ts + dur
                if page ~= current.last_page then
                    current.pages_read = current.pages_read + 1
                    current.last_page = page
                end
                current.end_percent = pct
            else
                flushCurrent()
                current = {
                    book_id = book_id,
                    partial_md5 = r.md5,
                    start_time = ts,
                    last_end_time = ts + dur,
                    duration_sec = dur,
                    pages_read = 1,
                    last_page = page,
                    start_percent = pct,
                    end_percent = pct,
                }
            end
        end
    end
    flushCurrent()
    return by_month
end

--- Exports monthly sessions from KOReader's statistics.sqlite3.
function Stats.exportMonthlySessions(md5_to_book_id, target_month)
    if not ok_sq3 or not SQ3 then return {} end
    local db_path = getStatsDbPath()
    local f = io.open(db_path, "rb")
    if not f then return {} end
    f:close()

    local ok_open, conn = pcall(SQ3.open, db_path, "ro")
    if not ok_open or not conn then return {} end

    local rows = {}
    local sql = [[
        SELECT b.md5, p.start_time, p.duration, p.page, p.total_pages
        FROM page_stat_data p
        JOIN book b ON b.id = p.id_book
        ORDER BY b.md5 ASC, p.start_time ASC
    ]]
    local ok_q, stmt = pcall(conn.prepare, conn, sql)
    if ok_q and stmt then
        while true do
            local row = stmt:step()
            if not row then break end
            table.insert(rows, {
                md5 = row[1],
                start_time = tonumber(row[2]),
                duration = tonumber(row[3]),
                page = tonumber(row[4]),
                total_pages = tonumber(row[5]),
            })
        end
        stmt:close()
    end
    conn:close()

    local by_month = Stats.aggregateRows(rows, md5_to_book_id)
    if target_month then
        return { [target_month] = by_month[target_month] or {} }
    end
    return by_month
end

--- Safely imports remote sessions into KOReader's statistics.sqlite3 (idempotent).
function Stats.importRemoteSessions(sessions, catalog_books)
    if not ok_sq3 or not SQ3 or not sessions or #sessions == 0 then return 0 end
    local db_path = getStatsDbPath()
    local f = io.open(db_path, "rb")
    if not f then return 0 end
    f:close()

    local ok_open, conn = pcall(SQ3.open, db_path)
    if not ok_open or not conn then return 0 end

    local imported = 0
    local md5_to_id = {}
    local q_books, stmt_b = pcall(conn.prepare, conn, "SELECT id, md5 FROM book WHERE md5 IS NOT NULL")
    if q_books and stmt_b then
        while true do
            local row = stmt_b:step()
            if not row then break end
            md5_to_id[row[2]] = tonumber(row[1])
        end
        stmt_b:close()
    end

    pcall(conn.exec, conn, "BEGIN TRANSACTION")
    local ok_ins, ins_stmt = pcall(conn.prepare, conn,
        "INSERT OR IGNORE INTO page_stat_data (id_book, page, start_time, duration, total_pages) VALUES (?, ?, ?, ?, ?)")
    if ok_ins and ins_stmt then
        for _, s in ipairs(sessions) do
            local pmd5 = s.partial_md5
            if (not pmd5 or pmd5 == "") and catalog_books and catalog_books[s.book_id] and catalog_books[s.book_id].hashes then
                pmd5 = catalog_books[s.book_id].hashes.partial_md5
            end
            local id_book = pmd5 and md5_to_id[pmd5]
            if id_book and s.start_time and s.duration_sec then
                ins_stmt:reset()
                ins_stmt:bind(id_book, 1, tonumber(s.start_time), tonumber(s.duration_sec), 100)
                local ok_step = pcall(ins_stmt.step, ins_stmt)
                if ok_step then imported = imported + 1 end
            end
        end
        ins_stmt:close()
    end
    pcall(conn.exec, conn, "COMMIT")
    conn:close()
    return imported
end

return Stats
