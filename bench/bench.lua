-- Throughput benchmark for simple-template.
--
--   lua bench/bench.lua            # default sizes
--   lua bench/bench.lua 1000 500   # <lines> <iterations>
--
-- Two scenarios, both watching for super-linear growth that would signal a
-- reintroduced O(n^2) scan:
--
--   1. "no-marker scaling" -- a realistic template (mostly plain prose, a
--      marker every ~20 lines) at growing line lengths. ms/render should stay
--      flat: plain lines are skipped by a substring pre-filter, not run through
--      the marker pattern.
--
--   2. "tail scaling" -- a single line with a marker near the front followed by
--      a growing run of plain text. ms/render should stay flat: the text after
--      the last marker must not be re-scanned by the lazy marker pattern. (A
--      naive whole-line gsub is quadratic in this tail.)
package.path = "./?.lua;../?.lua;" .. package.path
local T = require "simple-template"

local LINES = tonumber(arg and arg[1]) or 500
local ITERS = tonumber(arg and arg[2]) or 200
local LINE_LENGTHS = { 40, 80, 160 }
local MARKER_EVERY = 20

-- Build a template of `nlines` lines, each roughly `line_len` chars of plain
-- prose, with a single-marker line every `MARKER_EVERY` lines.
local function make_template(nlines, line_len)
    local unit = "ordinary configuration and documentation text "
    local prose = unit:rep(math.ceil(line_len / #unit)):sub(1, line_len)
    local out = {}
    for i = 1, nlines do
        out[i] = (i % MARKER_EVERY == 0) and 'value = "--[[ @@V@@ ]]"' or prose
    end
    return table.concat(out, "\n") .. "\n"
end

local function bench(tmpl, iters)
    local sources = { V = "5.2.2" }
    local t0 = os.clock()
    for _ = 1, iters do T.render_string(tmpl, sources) end
    return os.clock() - t0
end

-- A line with a marker near the front, then `tail_len` chars of plain text.
local function make_tail_line(tail_len)
    return 'value = "--[[ @@V@@ ]]" ' .. ("x"):rep(tail_len) .. "\n"
end

io.write(string.format("simple-template bench: %d lines x %d iterations\n\n", LINES, ITERS))

io.write("[1] no-marker scaling (ms/render should stay flat as line_len grows)\n")
io.write(string.format("%-12s %12s %14s %12s\n", "line_len", "total(s)", "ms/render", "MB/s"))
for _, len in ipairs(LINE_LENGTHS) do
    local tmpl = make_template(LINES, len)
    local dt = bench(tmpl, ITERS)
    local mb = (#tmpl * ITERS) / (1024 * 1024)
    io.write(string.format("%-12d %12.3f %14.4f %12.1f\n", len, dt, dt / ITERS * 1e3, mb / dt))
end

io.write("\n[2] tail scaling (ms/render should stay flat as tail_len grows)\n")
io.write(string.format("%-12s %12s %14s\n", "tail_len", "total(s)", "ms/render"))
local TAIL_ITERS = ITERS * 25
for _, tl in ipairs({ 100, 200, 400, 800 }) do
    local tmpl = make_tail_line(tl)
    local dt = bench(tmpl, TAIL_ITERS)
    io.write(string.format("%-12d %12.3f %14.5f\n", tl, dt, dt / TAIL_ITERS * 1e3))
end
