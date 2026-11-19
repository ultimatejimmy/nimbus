local json = require("json")
local Http = require("nimbus_http")
local OAuth = require("nimbus_cloud_oauth")
local GDrive = require("nimbus_cloud_gdrive")
local OneDrive = require("nimbus_cloud_onedrive")
local Dropbox = require("nimbus_cloud_dropbox")
local WebDAV = require("nimbus_cloud_webdav")

describe("CloudFS drivers (mocked HTTP)", function()
    local orig_request = Http.request
    local orig_get_token = OAuth.getValidAccessToken
    local calls = {}

    before_each(function()
        calls = {}
        OAuth.getValidAccessToken = function(provider, opts, cb)
            cb(true, "mock_token_" .. tostring(provider))
        end
        GDrive.clearFolderCache()
    end)

    after_each(function()
        Http.request = orig_request
        OAuth.getValidAccessToken = orig_get_token
    end)

    it("GDrive testConnection and downloadString work", function()
        Http.request = function(req)
            table.insert(calls, req)
            if req.url:find("/about", 1, true) then
                return 1, 200, {}, "200 OK", json.encode({ user = { emailAddress = "reader@example.com" } })
            elseif req.url:find("files?", 1, true) then
                return 1, 200, {}, "200 OK", json.encode({ files = { { id = "file123", name = "catalog.json" } } })
            elseif req.url:find("alt=media", 1, true) then
                return 1, 200, {}, "200 OK", '{"version":1}'
            end
            return 1, 404, {}, "404", ""
        end

        local ok_tc, email
        GDrive.testConnection({}, function(ok, res) ok_tc = ok; email = res end)
        assert.is_true(ok_tc)
        assert.are.equal("reader@example.com", email)

        local ok_dl, body
        GDrive.downloadString("Nimbus/_sync/catalog.json", {}, function(ok, res) ok_dl = ok; body = res end)
        assert.is_true(ok_dl)
        assert.are.equal('{"version":1}', body)
    end)

    it("OneDrive listDir parses folders and files", function()
        Http.request = function(req)
            table.insert(calls, req)
            return 1, 200, {}, "200 OK", json.encode({
                value = {
                    { id = "d1", name = "Books", folder = { childCount = 1 } },
                    { id = "f1", name = "catalog.json", size = 123 },
                },
            })
        end
        local ok_ls, entries
        OneDrive.listDir("Nimbus/_sync", {}, function(ok, res) ok_ls = ok; entries = res end)
        assert.is_true(ok_ls)
        assert.are.equal(2, #entries)
        assert.is_true(entries[1].is_dir)
        assert.is_false(entries[2].is_dir)
    end)

    it("Dropbox uploadString and downloadString work", function()
        Http.request = function(req)
            table.insert(calls, req)
            return 1, 200, {}, "200 OK", '{"ok":true}'
        end
        local ok_up
        Dropbox.uploadString("Nimbus/_sync/progress.json", '{"ok":true}', "application/json", {}, function(ok) ok_up = ok end)
        assert.is_true(ok_up)
        assert.are.equal("POST", calls[1].method)

        local ok_dl, body
        Dropbox.downloadString("Nimbus/_sync/progress.json", {}, function(ok, res) ok_dl = ok; body = res end)
        assert.is_true(ok_dl)
        assert.are.equal('{"ok":true}', body)
    end)

    it("WebDAV listDir parses PROPFIND XML", function()
        Http.request = function(req)
            table.insert(calls, req)
            local xml = [[<?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response><d:href>/dav/Nimbus/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
              <d:response><d:href>/dav/Nimbus/Books/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
              <d:response><d:href>/dav/Nimbus/catalog.json</d:href><d:propstat><d:prop><d:getcontentlength>42</d:getcontentlength></d:prop></d:propstat></d:response>
            </d:multistatus>]]
            return 1, 207, {}, "207 Multi-Status", xml
        end
        local ok_ls, entries
        WebDAV.listDir("Nimbus", { url = "https://example.com/dav", username = "u", password = "p" }, function(ok, res)
            ok_ls = ok; entries = res
        end)
        assert.is_true(ok_ls)
        assert.are.equal(2, #entries)
        assert.are.equal("Books", entries[1].name)
        assert.is_true(entries[1].is_dir)
        assert.are.equal("catalog.json", entries[2].name)
        assert.is_false(entries[2].is_dir)
        assert.are.equal(42, entries[2].size)
    end)
end)
