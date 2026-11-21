local Sync = require("nimbus_sync")

describe("nimbus_sync deduplication", function()
    it("deduplicates entries sharing partial_md5, sha256, or normalized title+author", function()
        local catalog = {
            books = {
                b1 = {
                    id = "b1",
                    title = "Dune",
                    authors = { "Frank Herbert" },
                    folder = "Books/Frank Herbert - Dune [b1]",
                    has_cover = true,
                    hashes = { partial_md5 = "pmd5_1", sha256 = "sha_1" },
                    added_at = "2026-01-01T00:00:00Z",
                },
                b2 = {
                    id = "b2",
                    title = "Dune",
                    authors = { "Frank Herbert" },
                    folder = "Books/Frank Herbert - Dune [b2]",
                    has_cover = false,
                    hashes = { partial_md5 = "pmd5_different", sha256 = "" },
                    added_at = "2026-01-02T00:00:00Z",
                },
                b3 = {
                    id = "b3",
                    title = "Mistborn",
                    authors = { "Brandon Sanderson" },
                    folder = "Books/Brandon Sanderson - Mistborn [b3]",
                    has_cover = true,
                    hashes = { partial_md5 = "pmd5_m", sha256 = "sha_m" },
                    added_at = "2026-01-01T00:00:00Z",
                },
                b4 = {
                    id = "b4",
                    title = "Mistborn (Copy)",
                    authors = { "Brandon Sanderson" },
                    folder = "Books/Brandon Sanderson - Mistborn [b4]",
                    has_cover = false,
                    hashes = { partial_md5 = "pmd5_m", sha256 = "" },
                    added_at = "2026-01-03T00:00:00Z",
                },
            },
        }

        local removed, dup_folders = Sync.deduplicateCatalog(catalog)
        assert.are.equal(2, removed)
        assert.are.equal(2, #dup_folders)
        assert.is_nil(catalog.books.b1.deleted)
        assert.is_true(catalog.books.b2.deleted)
        assert.is_nil(catalog.books.b3.deleted)
        assert.is_true(catalog.books.b4.deleted)
    end)
end)
