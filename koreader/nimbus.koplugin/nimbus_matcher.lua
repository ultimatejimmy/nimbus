--[[--
nimbus_matcher.lua
Resolves local book files to Nimbus catalog book_ids using priority matching:
1. Local book_links map (by_path)
2. Exact partial_md5
3. Exact sha256
4. Normalized (title, primary_author) or isbn fallback
--]]

local Settings = require("nimbus_settings")
local Hash = require("nimbus_hash")

local Matcher = {}

function Matcher.normalizeText(s)
    if not s then return "" end
    local out = tostring(s):lower()
    out = out:gsub("[%p%c]", " ")
    out = out:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return out
end

--- Resolves a local book against catalog.books.
-- @param filepath string
-- @param catalog table { books = { [id] = entry } }
-- @param doc_props table|nil optional { title, authors, isbn, partial_md5, sha256 }
-- @return book_id|nil, match_method|nil, candidates|nil
function Matcher.resolve(filepath, catalog, doc_props)
    catalog = catalog or {}
    local books = catalog.books or {}
    doc_props = doc_props or {}

    -- 1. Local link map
    if filepath then
        local links = Settings.loadBookLinks()
        local linked_id = links.by_path[filepath]
        if linked_id and books[linked_id] and not books[linked_id].deleted then
            return linked_id, "linked"
        end
    end

    -- 2. partial_md5
    local pmd5 = doc_props.partial_md5 or (filepath and Hash.partialMD5(filepath))
    if pmd5 then
        for id, entry in pairs(books) do
            if not entry.deleted and entry.hashes and entry.hashes.partial_md5 == pmd5 then
                if filepath then Settings.linkBook(filepath, id) end
                return id, "partial_md5"
            end
        end
    end

    -- 3. sha256
    local sha = doc_props.sha256 or (filepath and Hash.sha256File(filepath))
    if sha then
        for id, entry in pairs(books) do
            if not entry.deleted and entry.hashes and entry.hashes.sha256 == sha then
                if filepath then Settings.linkBook(filepath, id) end
                return id, "sha256"
            end
        end
    end

    -- 4. Fallback candidates by ISBN or normalized (title, author)
    local candidates = {}
    local norm_title = Matcher.normalizeText(doc_props.title)
    local norm_author = Matcher.normalizeText(doc_props.authors)
    local isbn = doc_props.isbn and tostring(doc_props.isbn):gsub("[^%w]", "") or nil

    for id, entry in pairs(books) do
        if not entry.deleted then
            local entry_isbn = entry.isbn and tostring(entry.isbn):gsub("[^%w]", "") or nil
            if isbn and isbn ~= "" and entry_isbn == isbn then
                table.insert(candidates, { id = id, entry = entry, reason = "isbn" })
            elseif norm_title ~= "" and Matcher.normalizeText(entry.title) == norm_title then
                local entry_author = ""
                if type(entry.authors) == "table" and entry.authors[1] then
                    entry_author = Matcher.normalizeText(entry.authors[1])
                elseif type(entry.authors) == "string" then
                    entry_author = Matcher.normalizeText(entry.authors)
                end
                if norm_author == "" or entry_author == "" or norm_author:find(entry_author, 1, true) or entry_author:find(norm_author, 1, true) then
                    table.insert(candidates, { id = id, entry = entry, reason = "title_author" })
                end
            end
        end
    end

    return nil, nil, candidates
end

return Matcher
