local Hash = require("nimbus_hash")
local ok_util, util = pcall(require, "util")

describe("nimbus_hash", function()
    it("matches KOReader util.partialMD5 on a 10KB test file", function()
        local path = "tests/tmp/sample_book.bin"
        local f = assert(io.open(path, "wb"))
        f:write(string.rep("ABCD1234", 1280)) -- 10240 bytes
        f:close()

        local h1 = Hash.partialMD5(path)
        assert.is_not_nil(h1)
        assert.are.equal(32, #h1)

        if ok_util and util and util.partialMD5 then
            local h2 = util.partialMD5(path)
            assert.are.equal(h2, h1)
        end
    end)

    it("computes deterministic annotation IDs", function()
        local id1 = Hash.annotationId("a1b2c3d4", "  There's always   another secret. ", "/body/p[1]")
        local id2 = Hash.annotationId("a1b2c3d4", "There's always another secret.", "/body/p[1]")
        assert.are.equal(id1, id2)
        assert.is_true(id1:match("^ann_[a-f0-9]+$") ~= nil)
    end)
end)
