local json = require("json")
local Merge = require("nimbus_merge")

local function readJson(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*all")
    f:close()
    return json.decode(s)
end

describe("nimbus_merge against spec/fixtures", function()
    local expected = readJson("../spec/fixtures/expected_merged.json")

    it("merges device progress deterministically", function()
        local a = readJson("../spec/fixtures/device_a_progress.json")
        local b = readJson("../spec/fixtures/device_b_progress.json")
        local merged = Merge.mergeProgress({ a, b })

        for book_id, exp in pairs(expected.progress) do
            assert.is_not_nil(merged[book_id])
            assert.are.equal(exp.device_id, merged[book_id].device_id)
            assert.are.equal(exp.percent, merged[book_id].percent)
            assert.are.equal(exp.updated_at, merged[book_id].updated_at)
        end
    end)

    it("merges device annotations with edits and tombstones", function()
        local a = readJson("../spec/fixtures/device_a_annotations.json")
        local b = readJson("../spec/fixtures/device_b_annotations.json")
        local merged = Merge.mergeAnnotations({ a, b })

        local book_res = merged["a1b2c3d4"]
        assert.is_not_nil(book_res)

        local active_ids = {}
        local by_id = {}
        for _, ann in ipairs(book_res.active) do
            table.insert(active_ids, ann.id)
            by_id[ann.id] = ann
        end
        table.sort(active_ids)
        assert.are.same(expected.annotations.a1b2c3d4.active_ids, active_ids)
        assert.are.equal(expected.annotations.a1b2c3d4.ann_002_note, by_id["ann_002"].note)
        assert.are.equal(expected.annotations.a1b2c3d4.ann_002_color, by_id["ann_002"].color)

        local tomb_ids = {}
        for _, ann in ipairs(book_res.all) do
            if ann.deleted then
                table.insert(tomb_ids, ann.id)
            end
        end
        table.sort(tomb_ids)
        assert.are.same(expected.annotations.a1b2c3d4.tombstone_ids, tomb_ids)
    end)

    it("merges and deduplicates reading sessions", function()
        local a = readJson("../spec/fixtures/device_a_sessions.json")
        local b = readJson("../spec/fixtures/device_b_sessions.json")
        local merged = Merge.mergeSessions({ a, b })

        assert.are.equal(#expected.sessions, #merged)
        for i, exp in ipairs(expected.sessions) do
            assert.are.equal(exp.device_id, merged[i].device_id)
            assert.are.equal(exp.book_id, merged[i].book_id)
            assert.are.equal(exp.start_time, merged[i].start_time)
            assert.are.equal(exp.duration_sec, merged[i].duration_sec)
        end
    end)
end)
