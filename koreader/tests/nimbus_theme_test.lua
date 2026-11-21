if not package.loaded["ffi/blitbuffer"] then
    package.loaded["ffi/blitbuffer"] = {
        COLOR_BLACK = 1,
        COLOR_WHITE = 2,
        COLOR_DARK_GRAY = 3,
        COLOR_LIGHT_GRAY = 4,
    }
end

local theme = require("nimbus_theme")

describe("nimbus_theme", function()
    after_each(function()
        package.loaded["features/sui_style"] = nil
        package.loaded["infra/sui_core"] = nil
    end)

    it("uses default font sizes and 1.0 icon density when Simple UI is inactive", function()
        package.loaded["features/sui_style"] = nil
        package.loaded["infra/sui_core"] = nil

        assert.is_false(theme.isSimpleUIActive())
        assert.are.equal(1.0, theme.getDensity())
        assert.are.equal(20, theme.fs("title"))
        assert.are.equal(18, theme.fs("subtitle"))
        assert.are.equal(16, theme.fs("body"))
        assert.are.equal(14, theme.fs("detail"))
        assert.are.equal(12, theme.fs("caption"))
        assert.are.equal(24, theme.icon(24))
        assert.are.equal(20, theme.icon(20))
    end)

    it("inherits SUIStyle tokens and 1.25x icon density when Simple UI is active", function()
        package.loaded["features/sui_style"] = {
            FS_TITLE = 22,
            FS_SUBTITLE = 20,
            FS_BODY = 18,
            FS_DETAIL = 15,
            FS_CAPTION = 12,
            FACE_BOLD = "NotoSans-Bold.ttf",
            FACE_REGULAR = "NotoSans-Regular.ttf",
        }

        assert.is_true(theme.isSimpleUIActive())
        assert.are.equal(1.25, theme.getDensity())
        assert.are.equal(22, theme.fs("title"))
        assert.are.equal(20, theme.fs("subtitle"))
        assert.are.equal(18, theme.fs("body"))
        assert.are.equal(15, theme.fs("detail"))
        assert.are.equal(12, theme.fs("caption"))
        assert.are.equal(30, theme.icon(24))
        assert.are.equal(25, theme.icon(20))
        assert.are.equal("NotoSans-Bold.ttf", theme.getTitleFontName())
        assert.are.equal("NotoSans-Regular.ttf", theme.getBodyFontName())
    end)

    it("selects 2 rows with even vertical spacing when 3 rows would shrink covers below 85%", function()
        local grid = theme.computeCoverGrid{
            sw = 600,
            avail_h = 597,
            cols = 3,
            margin_h = 14,
            grid_gap = 12,
            title_slot_h = 38,
            title_gap = 6,
            min_gap_v = 8,
            max_gap_v = 24,
        }

        assert.are.equal(2, grid.rows)
        assert.are.equal(6, grid.per_page)
        assert.is_true(grid.cover_slot_w >= math.floor(grid.cell_w * 0.85))
        assert.is_true(grid.grid_gap_v >= 8)
        assert.is_true(grid.grid_gap_v <= 24)
        local total_used = (grid.rows * grid.cover_row_h) + ((grid.rows + 1) * grid.grid_gap_v)
        assert.is_true(total_used <= 597)
    end)

    it("steps to 4 columns x 2 rows on Simple UI screens instead of dropping to 1 row", function()
        local grid = theme.computeCoverGrid{
            sw = 600,
            avail_h = 460,
            cols = 3,
            margin_h = 10,
            grid_gap = 10,
            title_slot_h = 41,
            title_gap = 6,
            min_gap_v = 8,
            max_gap_v = 24,
        }

        assert.are.equal(4, grid.cols)
        assert.are.equal(2, grid.rows)
        assert.are.equal(8, grid.per_page)
        assert.is_true(grid.cover_slot_w >= math.floor(grid.cell_w * 0.75))
        local total_used = (grid.rows * grid.cover_row_h) + ((grid.rows + 1) * grid.grid_gap_v)
        assert.is_true(total_used <= 460)
    end)

    it("falls back to 1 row on very short screens instead of clipping row 2", function()
        local grid = theme.computeCoverGrid{
            sw = 600,
            avail_h = 260,
            cols = 3,
            margin_h = 10,
            grid_gap = 10,
            title_slot_h = 41,
            title_gap = 6,
            min_gap_v = 8,
            max_gap_v = 24,
        }

        assert.are.equal(3, grid.cols)
        assert.are.equal(1, grid.rows)
        assert.are.equal(3, grid.per_page)
        local total_used = (grid.rows * grid.cover_row_h) + ((grid.rows + 1) * grid.grid_gap_v)
        assert.is_true(total_used <= 260)
    end)

    it("selects 3 rows on tall screens and caps vertical gap at max_gap_v", function()
        local grid = theme.computeCoverGrid{
            sw = 600,
            avail_h = 1100,
            cols = 3,
            margin_h = 14,
            grid_gap = 12,
            title_slot_h = 38,
            title_gap = 6,
            min_gap_v = 8,
            max_gap_v = 24,
        }

        assert.are.equal(3, grid.rows)
        assert.are.equal(9, grid.per_page)
        assert.are.equal(grid.cell_w, grid.cover_slot_w)
        assert.are.equal(24, grid.grid_gap_v)
    end)
end)
