-- Throughput benchmark for simple-template.
--
--   lua bench/bench.lua          # defaults
--   lua bench/bench.lua 1000 500 # <lines> <iterations>
--
-- Each sweep grows one dimension and prints ms/render. A flat column means
-- cost is linear in input size; super-linear growth flags a reintroduced
-- O(n^2) scan -- e.g. running the marker pattern over text that has no marker.
package.path = "./?.lua;../?.lua;" .. package.path
local T = require "simple-template"

local LINES = tonumber(arg and arg[1]) or 500
local ITERS = tonumber(arg and arg[2]) or 200
local SOURCES = { V = "5.2.2" }

-- Render `build(size)` `iters` times for each size and print one row each.
local function sweep(title, col, sizes, iters, build)
    io.write(string.format("\n%s\n%-10s %12s %14s\n", title, col, "total(s)", "ms/render"))
    for _, size in ipairs(sizes) do
        local tmpl = build(size)
        local t0 = os.clock()
        for _ = 1, iters do T.render_string(tmpl, SOURCES) end
        local dt = os.clock() - t0
        io.write(string.format("%-10d %12.3f %14.5f\n", size, dt, dt / iters * 1e3))
    end
end

io.write(string.format("simple-template bench: %d iterations (flat ms/render == linear)\n", ITERS))

-- [1] Grow line width: mostly plain prose, a marker every 20 lines. Plain
-- lines must be skipped, not pattern-matched.
sweep("[1] line width (" .. LINES .. " lines, marker every 20)", "line_len",
    { 40, 80, 160 }, ITERS, function(line_len)
        local unit = "ordinary configuration and documentation text "
        local prose = unit:rep(math.ceil(line_len / #unit)):sub(1, line_len)
        local out = {}
        for i = 1, LINES do
            out[i] = (i % 20 == 0) and 'value = "--[[ @@V@@ ]]"' or prose
        end
        return table.concat(out, "\n") .. "\n"
    end)

-- [2] Grow the tail after a single marker. The text past the last marker must
-- not be re-scanned by the lazy pattern.
sweep("[2] tail width (one marker, then plain text)", "tail_len",
    { 100, 200, 400, 800 }, ITERS * 25, function(tail_len)
        return 'value = "--[[ @@V@@ ]]" ' .. ("x"):rep(tail_len) .. "\n"
    end)
