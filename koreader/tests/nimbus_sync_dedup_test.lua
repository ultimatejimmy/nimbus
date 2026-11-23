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
                b5 = {
                    id = "b5",
                    title = "Career of Evil",
                    authors = { "Robert Galbraith" },
                    filename = "Career of Evil.epub",
                    size_bytes = 512000,
                    folder = "Books/Robert Galbraith - Career of Evil [b5]",
                    has_cover = true,
                    hashes = {},
                    added_at = "2026-01-01T00:00:00Z",
                },
                b6 = {
                    id = "b6",
                    title = "Career of Evil (Cormoran Strike)",
                    authors = { "Unknown Author" },
                    filename = "Career of Evil.epub",
                    size_bytes = 512000,
                    folder = "Books/Unknown - Career of Evil [b6]",
                    has_cover = false,
                    hashes = {},
                    added_at = "2026-01-04T00:00:00Z",
                },
                b7 = {
                    id = "b7",
                    title = "A Christmas Carol",
                    authors = { "Charles Dickens" },
                    filename = "Christmas Carol.epub",
                    size_bytes = 220000,
                    folder = "Books/Charles Dickens - A Christmas Carol [b7]",
                    has_cover = true,
                    hashes = {},
                    added_at = "2026-01-01T00:00:00Z",
                },
                b8 = {
                    id = "b8",
                    title = "A Christmas Carol (Annotated Edition)",
                    authors = { "Dickens, Charles" },
                    filename = "A Christmas Carol.mobi",
                    size_bytes = 129008,
                    folder = "Books/Dickens, Charles - A Christmas Carol [b8]",
                    has_cover = false,
                    hashes = {},
                    added_at = "2026-11-21T05:52:11Z",
                },
            },
        }

        local removed, dup_folders = Sync.deduplicateCatalog(catalog)
        assert.are.equal(4, removed)
        assert.are.equal(4, #dup_folders)
        assert.is_nil(catalog.books.b1.deleted)
        assert.is_true(catalog.books.b2.deleted)
        assert.is_nil(catalog.books.b3.deleted)
        assert.is_true(catalog.books.b4.deleted)
        assert.is_nil(catalog.books.b5.deleted)
        assert.is_true(catalog.books.b6.deleted)
        assert.is_nil(catalog.books.b7.deleted)
        assert.is_true(catalog.books.b8.deleted)
    end)

    it("matches Title+Author vs raw 'Title - Author' filename, restores clean deleted copy, and repairs metadata", function()
        local catalog = {
            books = {
                ah_num = {
                    id = "ah_num",
                    title = "Alexander Hamilton",
                    authors = { "Ron Chernow" },
                    filename = "Alexander Hamilton - Ron Chernow (169).epub",
                    folder = "Books/Ron Chernow - Alexander Hamilton [ah_num]",
                    has_cover = true,
                    hashes = { partial_md5 = "p1", sha256 = "s1" },
                    added_at = "2026-11-21T08:12:00Z",
                },
                ah_clean = {
                    id = "ah_clean",
                    title = "Alexander Hamilton - Ron Chernow",
                    authors = {},
                    filename = "Alexander Hamilton - Ron Chernow.epub",
                    folder = "Books/Unknown - Alexander Hamilton - Ron Chernow [ah_clean]",
                    has_cover = true,
                    hashes = { partial_md5 = "p2", sha256 = "s2" },
                    added_at = "2026-11-21T13:12:00Z",
                },
                fr_num = {
                    id = "fr_num",
                    title = "Frankenstein - Mary Shelley (145)",
                    authors = {},
                    filename = "Frankenstein - Mary Shelley (145).epub",
                    folder = "Books/Unknown - Frankenstein (145) [fr_num]",
                    has_cover = true,
                    hashes = { partial_md5 = "fp1", sha256 = "fs1" },
                    added_at = "2026-11-21T08:12:00Z",
                },
                fr_clean = {
                    id = "fr_clean",
                    title = "Frankenstein - Mary Shelley",
                    authors = {},
                    filename = "Frankenstein - Mary Shelley.epub",
                    folder = "Books/Unknown - Frankenstein [fr_clean]",
                    has_cover = true,
                    deleted = true,
                    hashes = { partial_md5 = "fp2", sha256 = "fs2" },
                    added_at = "2026-11-21T13:12:00Z",
                },
                cc_raw = {
                    id = "cc_raw",
                    title = "1 - Cuckoo's Calling, The - Robert Galbraith",
                    authors = {},
                    filename = "1 - Cuckoo's Calling, The - Robert Galbraith.epub",
                    folder = "Books/Unknown - Cuckoo [cc_raw]",
                    has_cover = true,
                    hashes = { partial_md5 = "cc1", sha256 = "ccs1" },
                    added_at = "2026-11-21T08:00:00Z",
                },
            },
        }

        local removed, dup_folders, repaired = Sync.deduplicateCatalog(catalog)
        assert.are.equal(2, removed)
        assert.are.equal(2, #dup_folders)
        assert.is_true(repaired > 0)
        assert.is_true(catalog.books.ah_num.deleted)
        assert.is_nil(catalog.books.ah_clean.deleted)
        assert.are.equal("Alexander Hamilton", catalog.books.ah_clean.title)
        assert.are.equal("Ron Chernow", catalog.books.ah_clean.authors[1])

        assert.is_true(catalog.books.fr_num.deleted)
        assert.is_false(catalog.books.fr_clean.deleted)
        assert.are.equal("Frankenstein", catalog.books.fr_clean.title)
        assert.are.equal("Mary Shelley", catalog.books.fr_clean.authors[1])

        assert.are.equal("The Cuckoo's Calling", catalog.books.cc_raw.title)
        assert.are.equal("Robert Galbraith", catalog.books.cc_raw.authors[1])
        assert.are.equal(1, catalog.books.cc_raw.series_index)
    end)
end)
