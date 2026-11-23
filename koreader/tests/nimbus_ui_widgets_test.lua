if not package.loaded["ffi/blitbuffer"] then
    package.loaded["ffi/blitbuffer"] = {
        COLOR_BLACK = 1,
        COLOR_WHITE = 2,
        COLOR_DARK_GRAY = 3,
        COLOR_LIGHT_GRAY = 4,
    }
end

local dev = package.loaded["device"]
if dev and dev.screen and not dev.screen.scaleBySize then
    dev.screen.scaleBySize = function(_, v) return v end
end

local function stubWidget(name)
    if package.loaded[name] then return end
    package.loaded[name] = {
        new = function(cls, o)
            o = o or {}
            o.getSize = o.getSize or function() return { w = o.width or 100, h = o.height or 30 } end
            o.free = o.free or function() end
            return o
        end,
        extend = function(cls, o) return o or {} end,
    }
end

for _, m in ipairs({
    "ui/widget/button",
    "ui/widget/container/centercontainer",
    "ui/widget/focusmanager",
    "ui/font",
    "ui/widget/container/framecontainer",
    "ui/geometry",
    "ui/gesturerange",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/imagewidget",
    "ui/widget/container/inputcontainer",
    "ui/widget/inputtext",
    "ui/widget/linewidget",
    "ui/widget/overlapgroup",
    "ui/widget/textboxwidget",
    "ui/widget/textwidget",
    "ui/uimanager",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
}) do
    stubWidget(m)
end
package.loaded["ui/font"].getFace = function() return {} end

local Widgets = require("nimbus_ui_widgets")
local SelectMixin = require("nimbus_ui_select")

describe("nimbus_ui_widgets action grid & select", function()
    it("groups flat actions into 2-column rows and preserves trailing odd item", function()
        local items = {
            { text = "Book cover" },
            { text = "Book description" },
            { text = "Open with…" },
            { text = "Show folder" },
            { text = "Reset" },
        }
        local rows = Widgets.buildActionGridRows(items, 2)
        assert.are.equal(3, #rows)
        assert.are.equal(2, #rows[1])
        assert.are.equal(2, #rows[2])
        assert.are.equal(1, #rows[3])
        assert.are.equal("Reset", rows[3][1].text)
    end)

    it("skips nil or empty-text items when building grid rows", function()
        local items = {
            { text = "" },
            { text = "Rename" },
            {},
            { text = "Delete" },
            { text = "Book Details" },
        }
        local rows = Widgets.buildActionGridRows(items, 2)
        assert.are.equal(2, #rows)
        assert.are.equal("Rename", rows[1][1].text)
        assert.are.equal("Delete", rows[1][2].text)
        assert.are.equal("Book Details", rows[2][1].text)
    end)

    it("renders createActionGrid with equal-width pairs and full-width odd row", function()
        local items = {
            { text = "A", callback = function() end },
            { text = "B", callback = function() end },
            { text = "C", callback = function() end },
        }
        local vg = Widgets.createActionGrid(items, 380, { cols = 2, gap = 8 })
        -- 2 rows + 1 vertical span = 3 children
        assert.are.equal(3, #vg)
        local row1 = vg[1]
        local row2 = vg[3]
        -- Row 1: btn1, span, btn2
        assert.are.equal(3, #row1)
        -- Row 2: single full-width button
        assert.are.equal(1, #row2)
    end)

    it("computes selection keys for local, cloud, and folder items", function()
        assert.are.equal("/books/a.epub", SelectMixin.getSelectionKey({ local_path = "/books/a.epub", cloud_id = "c1" }))
        assert.are.equal("c2", SelectMixin.getSelectionKey({ cloud_id = "c2" }))
        assert.are.equal("c3", SelectMixin.getSelectionKey({ id = "c3" }))
        assert.is_nil(SelectMixin.getSelectionKey({ is_folder = true, path = "/books/sub" }))
    end)
end)
