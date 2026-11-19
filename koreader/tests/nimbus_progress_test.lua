local Http = require("nimbus_http")

describe("nimbus_progress and streaming HTTP progress", function()
    it("makeFileProgressSource streams chunks, reports progress, and supports cancel", function()
        local path = "tests/tmp/progress_src.bin"
        local payload = string.rep("NIMBUS", 512) -- 3072 bytes
        local wf = assert(io.open(path, "wb"))
        wf:write(payload)
        wf:close()

        local rf = assert(io.open(path, "rb"))
        local calls = {}
        local src = Http.makeFileProgressSource(rf, #payload, function(sent, total, phase)
            table.insert(calls, { sent = sent, total = total, phase = phase })
        end, function() return false end)

        local out = {}
        while true do
            local chunk = src()
            if not chunk then break end
            table.insert(out, chunk)
        end
        rf:close()

        assert.are.equal(payload, table.concat(out))
        assert.is_true(#calls >= 1)
        assert.are.equal(#payload, calls[#calls].sent)
        assert.are.equal("finalizing", calls[#calls].phase)

        -- Cancel check
        local rf2 = assert(io.open(path, "rb"))
        local canceled_src = Http.makeFileProgressSource(rf2, #payload, nil, function() return true end)
        local c_chunk, c_err = canceled_src()
        rf2:close()
        assert.is_nil(c_chunk)
        assert.are.equal("canceled", c_err)
    end)

    it("makeFileProgressSink writes chunks and reports completion", function()
        local path = "tests/tmp/progress_dst.bin"
        local wf = assert(io.open(path, "wb"))
        local calls = {}
        local sink = Http.makeFileProgressSink(wf, 10, function(rec, total, phase)
            table.insert(calls, { rec = rec, total = total, phase = phase })
        end, function() return false end)

        assert.are.equal(1, sink("hello"))
        assert.are.equal(1, sink("world"))
        assert.are.equal(1, sink(nil))

        local rf = assert(io.open(path, "rb"))
        local content = rf:read("*all")
        rf:close()
        assert.are.equal("helloworld", content)
        assert.are.equal("done", calls[#calls].phase)
    end)
end)
