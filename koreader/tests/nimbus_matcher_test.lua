local json = require("json")
local Matcher = require("nimbus_matcher")
local Settings = require("nimbus_settings")

describe("nimbus_matcher", function()
    local f = assert(io.open("../spec/fixtures/catalog.json", "rb"))
    local catalog = json.decode(f:read("*all"))
    f:close()

    before_each(function()
        os.remove("tests/tmp/settings/nimbus/book_links.lua")
    end)

    it("matches by partial_md5 and persists local link", function()
        local id, method = Matcher.resolve("tests/tmp/mistborn.epub", catalog, {
            partial_md5 = "d41d8cd98f00b204e9800998ecf8427e",
        })
        assert.are.equal("a1b2c3d4", id)
        assert.are.equal("partial_md5", method)

        local id2, method2 = Matcher.resolve("tests/tmp/mistborn.epub", catalog, {})
        assert.are.equal("a1b2c3d4", id2)
        assert.are.equal("linked", method2)
    end)

    it("returns fallback candidates by normalized title and author", function()
        local id, _, candidates = Matcher.resolve("tests/tmp/other.epub", catalog, {
            partial_md5 = "ffffffffffffffffffffffffffffffff",
            sha256 = "0000",
            title = "Mistborn: The Final Empire",
            authors = "Brandon Sanderson",
        })
        assert.is_nil(id)
        assert.are.equal(1, #candidates)
        assert.are.equal("a1b2c3d4", candidates[1].id)
    end)
end)
