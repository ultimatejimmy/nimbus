local Scanner = require("nimbus_scanner")
local Settings = require("nimbus_settings")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs or not lfs then
    ok_lfs, lfs = pcall(require, "lfs")
end

local function mkdir_p(path)
    if not lfs or not lfs.mkdir then return end
    local acc = ""
    for part in path:gmatch("[^/]+") do
        acc = (acc == "") and part or (acc .. "/" .. part)
        lfs.mkdir(acc)
    end
end

local function write_bytes(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content)
    f:close()
end

describe("nimbus_scanner", function()
    local tmp_root = "tests/tmp/scanner_test"

    before_each(function()
        Settings.clearCache()
        Scanner.invalidateCache()
        os.remove("tests/tmp/settings/nimbus/settings.lua")
        os.remove("tests/tmp/settings/nimbus/book_links.lua")
        os.execute("rm -rf " .. tmp_root)
        mkdir_p(tmp_root)
    end)

    it("identifies supported book formats case-insensitively", function()
        assert.is_true(Scanner.isBookFile("book.epub"))
        assert.is_true(Scanner.isBookFile("BOOK.EPUB"))
        assert.is_true(Scanner.isBookFile("paper.pdf"))
        assert.is_true(Scanner.isBookFile("comic.cbz"))
        assert.is_false(Scanner.isBookFile("cover.jpg"))
        assert.is_false(Scanner.isBookFile("metadata.epub.lua"))
        assert.is_false(Scanner.isBookFile("notes.sdr"))
        assert.is_false(Scanner.isBookFile(""))
        assert.is_false(Scanner.isBookFile(nil))
    end)

    it("reads metadata from .sdr sidecar files", function()
        local book_path = tmp_root .. "/christmas.epub"
        local sdr_dir = tmp_root .. "/christmas.sdr"
        mkdir_p(sdr_dir)
        Settings.writeLuaTable(sdr_dir .. "/metadata.epub.lua", {
            doc_props = {
                title = "A Christmas Carol",
                authors = "Charles Dickens",
                language = "en",
            },
            percent_finished = 0.42,
            partial_md5_checksum = "abc123md5",
        })

        local meta = Scanner.readSidecarMeta(book_path)
        assert.are.equal("A Christmas Carol", meta.title)
        assert.are.equal("Charles Dickens", meta.authors)
        assert.are.equal("en", meta.language)
        assert.are.equal(0.42, meta.percent)
        assert.are.equal("reading", meta.status)
        assert.are.equal("abc123md5", meta.partial_md5)
    end)

    it("scans directories recursively while skipping .sdr and hidden folders", function()
        mkdir_p(tmp_root .. "/sub")
        mkdir_p(tmp_root .. "/book1.sdr")
        mkdir_p(tmp_root .. "/.hidden")

        write_bytes(tmp_root .. "/book1.epub", "epub-bytes")
        write_bytes(tmp_root .. "/sub/book2.pdf", "pdf-bytes")
        write_bytes(tmp_root .. "/sub/cover.jpg", "jpg-bytes")
        write_bytes(tmp_root .. "/book1.sdr/ignored.epub", "should-skip")
        write_bytes(tmp_root .. "/.hidden/secret.epub", "should-skip")

        local seen, out = {}, {}
        Scanner.scanDirectory(tmp_root, seen, out)
        table.sort(out)

        assert.are.equal(2, #out)
        assert.are.equal(tmp_root .. "/book1.epub", out[1])
        assert.are.equal(tmp_root .. "/sub/book2.pdf", out[2])
    end)

    it("scans local books and matches against cloud catalog", function()
        mkdir_p(tmp_root .. "/library/cloud_book.sdr")
        local cloud_book = tmp_root .. "/library/cloud_book.epub"
        local local_only = tmp_root .. "/library/local_only.epub"

        write_bytes(cloud_book, "cloud-book-content-12345")
        write_bytes(local_only, "local-only-content-67890")

        Settings.writeLuaTable(tmp_root .. "/library/cloud_book.sdr/metadata.epub.lua", {
            doc_props = {
                title = "Cloud Matched Book",
                authors = "Author One",
            },
            percent_finished = 0.5,
            partial_md5_checksum = "matched_pmd5_1",
        })

        Settings.save({
            provider = "gdrive",
            custom_books_dirs = { tmp_root .. "/library" },
        })

        local catalog = {
            books = {
                ["cloud-id-1"] = {
                    id = "cloud-id-1",
                    title = "Cloud Matched Book",
                    authors = "Author One",
                    hashes = { partial_md5 = "matched_pmd5_1" },
                },
            },
        }

        local scanned = Scanner.scanLocalBooks(catalog)
        assert.are.equal(2, #scanned)

        local by_path = {}
        for _, b in ipairs(scanned) do
            by_path[b.local_path] = b
        end

        assert.is_true(by_path[cloud_book].is_in_cloud)
        assert.are.equal("cloud-id-1", by_path[cloud_book].cloud_id)
        assert.are.equal("Cloud Matched Book", by_path[cloud_book].title)
        assert.are.equal("Author One", by_path[cloud_book].authors)

        assert.is_false(by_path[local_only].is_in_cloud)
        assert.is_nil(by_path[local_only].cloud_id)
        assert.are.equal("local_only", by_path[local_only].title)
        assert.are.equal("epub", by_path[local_only].format)
    end)

    it("deduplicates duplicate local copies of the same book and keeps canonical filename", function()
        mkdir_p(tmp_root .. "/dups")
        local copy1 = tmp_root .. "/dups/Gone Girl (1).epub"
        local canonical = tmp_root .. "/dups/Gone Girl.epub"
        write_bytes(copy1, "identical-gone-girl-bytes-12345")
        write_bytes(canonical, "identical-gone-girl-bytes-12345")

        Settings.save({
            provider = "gdrive",
            custom_books_dirs = { tmp_root .. "/dups" },
        })

        local scanned = Scanner.scanLocalBooks({ books = {} })
        assert.are.equal(1, #scanned)
        assert.are.equal("Gone Girl.epub", scanned[1].filename)
        assert.are.equal("Gone Girl", scanned[1].title)
        assert.are.equal(2, #scanned[1].all_local_paths)
    end)

    it("lists folders first and books directly inside the current folder", function()
        mkdir_p(tmp_root .. "/tree/Sci-Fi")
        mkdir_p(tmp_root .. "/tree/EmptyFolder")
        write_bytes(tmp_root .. "/tree/RootBook.epub", "root-book-bytes")
        write_bytes(tmp_root .. "/tree/Sci-Fi/Dune.epub", "dune-book-bytes")

        Settings.save({
            provider = "none",
            custom_books_dirs = { tmp_root .. "/tree" },
        })
        local scanned = Scanner.scanLocalBooks({ books = {} })
        local root_view = Scanner.listFolderContents(nil, scanned, { tmp_root .. "/tree" })

        assert.is_false(root_view.can_go_up)
        assert.are.equal(1, #root_view.folders)
        assert.are.equal("Sci-Fi", root_view.folders[1].name)
        assert.are.equal(1, root_view.folders[1].book_count)
        assert.are.equal(1, #root_view.books)
        assert.are.equal("RootBook", root_view.books[1].title)

        local sub_view = Scanner.listFolderContents(root_view.folders[1].path, scanned, { tmp_root .. "/tree" })
        assert.is_true(sub_view.can_go_up)
        assert.are.equal(0, #sub_view.folders)
        assert.are.equal(1, #sub_view.books)
        assert.are.equal("Dune", sub_view.books[1].title)

        -- Verify sample_books for 2x2 folder mosaic
        assert.are.equal(1, #root_view.folders[1].sample_books)
        assert.are.equal("Dune", root_view.folders[1].sample_books[1].title)
    end)

    it("respects KOReader collate_mixed and reverse_collate settings and caches local books", function()
        mkdir_p(tmp_root .. "/mix/MiddleFolder")
        write_bytes(tmp_root .. "/mix/AlphaBook.epub", "alpha-bytes")
        write_bytes(tmp_root .. "/mix/MiddleFolder/Inside.epub", "inside-bytes")
        write_bytes(tmp_root .. "/mix/ZetaBook.epub", "zeta-bytes")

        Settings.save({
            provider = "none",
            custom_books_dirs = { tmp_root .. "/mix" },
        })
        local scanned = Scanner.scanLocalBooks({ books = {} })
        local cached = Scanner.getCachedLocalBooks({ books = {} })
        assert.are.equal(#scanned, #cached)

        -- Mixed sorting: AlphaBook, MiddleFolder, ZetaBook
        _G.G_reader_settings = {
            isTrue = function(_, key)
                return key == "collate_mixed"
            end,
        }
        local mixed = Scanner.listFolderContents(nil, cached, { tmp_root .. "/mix" })
        assert.are.equal(3, #mixed.items)
        assert.are.equal("AlphaBook", mixed.items[1].title)
        assert.is_true(mixed.items[2].is_folder)
        assert.are.equal("MiddleFolder", mixed.items[2].name)
        assert.are.equal("ZetaBook", mixed.items[3].title)

        -- Non-mixed + reverse: MiddleFolder first, then ZetaBook, AlphaBook
        _G.G_reader_settings = {
            isTrue = function(_, key)
                return key == "reverse_collate"
            end,
        }
        local unmixed = Scanner.listFolderContents(nil, cached, { tmp_root .. "/mix" })
        assert.is_true(unmixed.items[1].is_folder)
        assert.are.equal("ZetaBook", unmixed.items[2].title)
        assert.are.equal("AlphaBook", unmixed.items[3].title)
        _G.G_reader_settings = nil
    end)

    it("computes relative_dir and lists cloud folders hierarchically", function()
        local roots = { "/mnt/c/ko_library" }
        assert.are.equal("Beeline", Scanner.getRelativeDir("/mnt/c/ko_library/Beeline/Gone Girl.epub", roots))
        assert.are.equal("Sci-Fi/2025", Scanner.getRelativeDir("/mnt/c/ko_library/Sci-Fi/2025/Dune.epub", roots))
        assert.are.equal("", Scanner.getRelativeDir("/mnt/c/ko_library/Root.epub", roots))

        local cloud_books = {
            { id = "1", title = "Root Book", relative_dir = "" },
            { id = "2", title = "Gone Girl", relative_dir = "Beeline" },
            { id = "3", title = "Dune", relative_dir = "Sci-Fi/2025" },
        }
        local root_cloud = Scanner.listCloudFolderContents("", cloud_books)
        assert.is_false(root_cloud.can_go_up)
        assert.are.equal(2, #root_cloud.folders)
        assert.are.equal("Beeline", root_cloud.folders[1].name)
        assert.are.equal(1, root_cloud.folders[1].book_count)
        assert.are.equal("Sci-Fi", root_cloud.folders[2].name)
        assert.are.equal(1, #root_cloud.books)
        assert.are.equal("Root Book", root_cloud.books[1].title)

        local sub_cloud = Scanner.listCloudFolderContents("Beeline", cloud_books)
        assert.is_true(sub_cloud.can_go_up)
        assert.are.equal("", sub_cloud.parent_dir)
        assert.are.equal(0, #sub_cloud.folders)
        assert.are.equal(1, #sub_cloud.books)
        assert.are.equal("Gone Girl", sub_cloud.books[1].title)
    end)
end)
