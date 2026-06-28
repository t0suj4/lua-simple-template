-- Behavioral spec for simple-template (busted).
--
--   luarocks install busted
--   busted            # from the repo root
--
-- Loads the module whether the file is template.lua or simple-template.lua,
-- and whether busted is run from the repo root or from spec/.
package.path = "./?.lua;../?.lua;" .. package.path
local T = require "simple-template"
-- Most cases use the in-memory entry point.
local function rs(tmpl, sources, opt) return T.render_string(tmpl, sources, opt) end

-- Assert `fn` raises an error whose message contains `needle` (plain substring;
-- messages carry a file:line prefix). On failure it reports both the wanted
-- substring and the actual message, so a near-miss is obvious instead of a bare
-- `false`.
local function raises(fn, needle)
  local ok, msg = pcall(fn)
  assert.is_false(ok, "expected an error, but the call returned normally")
  msg = tostring(msg)
  assert.is_true(msg:find(needle, 1, true) ~= nil, string.format(
    "error message missing expected substring\n  wanted: %s\n  actual: %s", needle, msg))
end

-- Render under an instruction budget so an accidental infinite loop fails the
-- test cleanly instead of hanging the whole suite. Runs in a coroutine with a
-- count hook; if the budget is exhausted the resume returns false and we raise.
local function rs_bounded(tmpl, sources, opt, budget)
  local co = coroutine.create(function() return T.render_string(tmpl, sources, opt) end)
  debug.sethook(co, function() error("instruction budget exceeded (likely infinite loop)") end,
    "", budget or 2000000)
  local ok, ret = coroutine.resume(co)
  debug.sethook(co)
  assert.is_true(ok, "render did not terminate: " .. tostring(ret))
  return ret
end

describe("simple-template", function()
  -- Temp files for the file-based API; cleaned up after each example.
  local tmpfiles
  before_each(function() tmpfiles = {} end)
  after_each(function()
    for _, p in ipairs(tmpfiles) do os.remove(p) end
  end)
  local function tmpwrite(content)
    local p = os.tmpname()
    local f = assert(io.open(p, "wb")); f:write(content); f:close()
    tmpfiles[#tmpfiles + 1] = p
    return p
  end

  describe("sources", function()
    it("substitutes a literal string", function()
      assert.are.equal('"v":"5.2.2",\n', rs('"v":"--[[ @@V@@ ]]",\n', { V = "5.2.2" }))
    end)

    it("accepts numbers via as_string", function()
      assert.are.equal("n=42\n", rs("n=--[[ @@N@@ ]]\n", { N = T.as_string(42) }))
    end)

    it("rejects a bare number source", function()
      raises(function() rs("n=--[[ @@N@@ ]]\n", { N = 42 }) end,
        "Source must be a string or a table")
    end)

    it("expands an array as a re-indented block", function()
      assert.are.equal("  a\n  b\n", rs("  --[[ @@A@@ ]]\n", { A = { "a", "b" } }))
    end)

    it("splits a multi-line literal via as_lines", function()
      assert.are.equal("  x\n  y\n  z\n", rs("  --[[ @@B@@ ]]\n", { B = T.as_lines("x\ny\nz") }))
    end)

    it("as_lines coerces numbers", function()
      assert.are.equal("  42\n", rs("  --[[ @@B@@ ]]\n", { B = T.as_lines(42) }))
    end)

    it("reads file contents via as_path", function()
      local p = tmpwrite("L1\nL2\n")
      assert.are.equal("  L1\n  L2\n", rs("  --[[ @@F@@ ]]\n", { F = T.as_path(p) }))
    end)

    describe("as_callback (per-variable)", function()
      it("produces a replacement dynamically", function()
        assert.are.equal("v=DYN:C\n",
          rs("v=--[[ @@C@@ ]]\n", { C = T.as_callback(function(marker) return { "DYN:" .. marker } end) }))
      end)

      it("can return a multi-line block", function()
        assert.are.equal("  a\n  b\n",
          rs("  --[[ @@C@@ ]]\n", { C = T.as_callback(function() return { "a", "b" } end) }))
      end)

      it("rejects a non-table return", function()
        raises(function()
          rs("v=--[[ @@C@@ ]]\n", { C = T.as_callback(function() return "oops" end) })
        end, "callback should return a table")
      end)

      it("rejects a non-callable constructor argument", function()
        raises(function() T.as_callback(42) end, "Expected callable")
      end)
    end)
  end)

  -- The callback contract: render-time callables (as_callback and the
  -- undefined_policy.value form) receive a fixed argument list, may build a
  -- block in block position but only one line inline, and their output is
  -- escaped like any other value. Tagged #callback for isolation.
  describe("callback contract #callback", function()
    -- Signature: (marker, esc, esc_rules, ctx), where
    -- ctx = { line, start, chunk, snippet }.
    it("passes the documented argument list", function()
      local got
      local cb = T.as_callback(function(...) got = { n = select("#", ...), ... }; return { "X" } end)
      rs("  pre --[[ j@@C@@j ]] post\n", { C = cb },
        { escape = { j = { method = "prefix", prefix = "\\", characters = "!" } } })
      assert.are.equal(4, got.n)
      assert.are.equal("C", got[1])                            -- marker name
      assert.are.equal("j", got[2])                            -- escape name
      assert.are.equal("table", type(got[3]))                  -- compiled escape rules
      local ctx = got[4]                                       -- context table
      assert.are.equal("  pre --[[ j@@C@@j ]] post", ctx.line)    -- whole line
      assert.are.equal("  pre ", ctx.start)                       -- text before the marker
      assert.are.equal("  pre --[[ j@@C@@j ]]", ctx.chunk)        -- start .. snippet
      assert.are.equal("--[[ j@@C@@j ]]", ctx.snippet)            -- just the marker
    end)

    it("passes the same argument list to an undefined_policy callback", function()
      local got
      rs("a=--[[ @@MISSING@@ ]]z\n", {}, {
        undefined_policy = { action = "quiet", value = function(...)
          got = { n = select("#", ...), ... }; return { "?" }
        end },
      })
      assert.are.equal(4, got.n)
      assert.are.equal("MISSING", got[1])                      -- marker name
      assert.are.equal("", got[2])                             -- esc
      assert.are.equal("a=", got[4].start)                     -- ctx.start
    end)

    it("expands a block-position callback into many lines", function()
      local cb = T.as_callback(function()
        local out = {}
        for i = 1, 3 do out[#out + 1] = "row " .. i end
        return out
      end)
      assert.are.equal("  row 1\n  row 2\n  row 3\n", rs("  --[[ @@R@@ ]]\n", { R = cb }))
    end)

    it("rejects a multi-line return in inline position", function()
      local cb = T.as_callback(function() return { "a", "b" } end)
      raises(function() rs("x=--[[ @@C@@ ]]\n", { C = cb }) end,
        "lines in an inline expansion")
    end)

    it("invokes the callback once per occurrence, left-to-right then top-down", function()
      local n = 0
      local cb = T.as_callback(function() n = n + 1; return { tostring(n) } end)
      assert.are.equal("1x2\n3\n",
        rs("--[[ @@K@@ ]]x--[[ @@K@@ ]]\n--[[ @@K@@ ]]\n", { K = cb }))
    end)

    it("escapes callback output inline", function()
      local cb = T.as_callback(function() return { 'a"b' } end)
      assert.are.equal('v=a\\"b\n', rs("v=--[[ j@@C@@j ]]\n", { C = cb },
        { escape = { j = { method = "prefix", prefix = "\\", characters = '"' } } }))
    end)

    it("escapes every line of callback output in block position", function()
      local cb = T.as_callback(function() return { 'a"', 'b"' } end)
      assert.are.equal('a\\"\nb\\"\n', rs("--[[ j@@C@@j ]]\n", { C = cb },
        { escape = { j = { method = "prefix", prefix = "\\", characters = '"' } } }))
    end)

    it("accepts a __call table as a callback", function()
      local ct = setmetatable({}, { __call = function() return { "CT" } end })
      assert.are.equal("v=CT\n", rs("v=--[[ @@C@@ ]]\n", { C = T.as_callback(ct) }))
    end)

    -- A callback may itself return another callback; the engine trampolines
    -- until it gets a plain array of lines (bounded against runaway recursion).
    it("resolves a callback that returns another callback", function()
      local inner = T.as_callback(function() return { "deep" } end)
      local outer = T.as_callback(function() return inner end)
      assert.are.equal("v=deep\n", rs("v=--[[ @@C@@ ]]\n", { C = outer }))
    end)

    it("resolves a deep callback chain", function()
      local function chain(n)
        if n == 0 then return T.as_callback(function() return { "bottom" } end) end
        return T.as_callback(function() return chain(n - 1) end)
      end
      assert.are.equal("v=bottom\n", rs("v=--[[ @@C@@ ]]\n", { C = chain(10) }))
    end)

    -- Acceptance (red until the depth guard reports itself): an unbounded chain
    -- must fail with a diagnostic that names the cause, not the misleading
    -- "inline expansion" / "concatenate a table" fall-through it produces today.
    it("reports a clear error when the callback chain is too deep", function()
      local loopcb; loopcb = T.as_callback(function() return loopcb end)
      raises(function() rs("v=--[[ @@C@@ ]]\n", { C = loopcb }) end, "callback chain")
    end)
  end)

  describe("rendering", function()
    it("preserves text after an inline marker", function()
      assert.are.equal('"v":"x",end\n', rs('"v":"--[[ @@V@@ ]]",end\n', { V = "x" }))
    end)

    it("passes through lines without markers", function()
      assert.are.equal("plain\n", rs("plain\n", {}))
    end)
  end)

  describe("escaping", function()
    local function esc(rule) return { escape = { e = rule } } end

    it("prefix: escapes quotes and backslashes for JSON", function()
      assert.are.equal('"d":"say \\"hi\\"\\\\bye",\n',
        rs('"d":"--[[ e@@D@@e ]]",\n', { D = 'say "hi"\\bye' },
          esc({ method = "prefix", prefix = "\\", characters = '"\\' })))
    end)

    it("double: doubles each listed character", function()
      assert.are.equal("a''b\n", rs("--[[ e@@V@@e ]]\n", { V = "a'b" },
        esc({ method = "double", characters = "'" })))
    end)

    it("surround: wraps each listed character", function()
      assert.are.equal("*x*\n", rs("--[[ e@@V@@e ]]\n", { V = "x" },
        esc({ method = "surround", surround = "*", characters = "x" })))
    end)

    it("hexcode: emits prefix + hex byte", function()
      assert.are.equal("\\x41\n", rs("--[[ e@@V@@e ]]\n", { V = "A" },
        esc({ method = "hexcode", prefix = "\\x", characters = "A" })))
    end)

    it("applies a multi-rule array in order", function()
      assert.are.equal('x=a*\'*b\\"c\n', rs("x=--[[ q@@T@@q ]]\n", { T = "a'b\"c" },
        { escape = { q = {
          { method = "surround", surround = "*", characters = "'" },
          { method = "prefix", prefix = "\\", characters = '"' },
        } } }))
    end)

    it("escapes every line of a block", function()
      assert.are.equal('  a\\"b\n  c\\"d\n', rs("  --[[ e@@A@@e ]]\n", { A = { 'a"b', 'c"d' } },
        esc({ method = "prefix", prefix = "\\", characters = '"' })))
    end)

    describe("callback method", function()
      it("uses a plain function", function()
        assert.are.equal("v=ABC\n", rs("v=--[[ e@@V@@e ]]\n", { V = "abc" },
          esc({ method = "callback", callback = function(t) return t:upper() end })))
      end)

      it("uses a callable (__call) table", function()
        local ct = setmetatable({}, { __call = function(_, t) return "[" .. t .. "]" end })
        assert.are.equal("v=[x]\n", rs("v=--[[ e@@V@@e ]]\n", { V = "x" },
          esc({ method = "callback", callback = ct })))
      end)
    end)
  end)

  describe("undefined-variable policy", function()
    it("errors by default", function()
      raises(function() rs("--[[ @@NOPE@@ ]]\n", {}) end,
        "Unknown template var: NOPE")
    end)

    it("quiet + empty drops the marker, keeps surrounding text", function()
      assert.are.equal("x=y\n", rs("x=--[[ @@N@@ ]]y\n", {},
        { undefined_policy = { action = "quiet", value = "empty" } }))
    end)

    it("quiet + keep leaves the original line untouched", function()
      assert.are.equal("--[[ @@N@@ ]]\n", rs("--[[ @@N@@ ]]\n", {},
        { undefined_policy = { action = "quiet", value = "keep" } }))
    end)

    it("callback value supplies a fallback", function()
      assert.are.equal("v=fb:N\n", rs("v=--[[ @@N@@ ]]\n", {},
        { undefined_policy = { action = "quiet", value = function(m) return { "fb:" .. m } end } }))
    end)

    it("rejects an unknown action", function()
      raises(function()
        rs("--[[ @@N@@ ]]\n", {}, { undefined_policy = { action = "bogus" } })
      end, "undefined_policy.action")
    end)

    it("rejects an unknown value", function()
      raises(function()
        rs("--[[ @@N@@ ]]\n", {}, { undefined_policy = { action = "quiet", value = "bogus" } })
      end, "value")
    end)
  end)

  describe("error paths", function()
    it("flags an escape-marker mismatch", function()
      raises(function()
        rs("--[[ a@@V@@b ]]\n", { V = "x" }, { escape = { a = { method = "double", characters = "x" } } })
      end, "Escape marker differs")
    end)

    it("flags an unknown escape rule", function()
      raises(function() rs('"--[[ zz@@V@@zz ]]"\n', { V = "x" }) end,
        "Unknown escape rule zz")
    end)

    it("forbids trailing text after a block marker", function()
      raises(function() rs("  --[[ @@A@@ ]]x\n", { A = { "a", "b" } }) end,
        "Trailing text after block")
    end)

    it("forbids more than one separating space", function()
      raises(function() rs("--[[  @@V@@ ]]\n", { V = "x" }) end,
        "At most 1 separating space")
    end)

    it("rejects a non-callable escape callback", function()
      raises(function()
        rs("v=--[[ z@@V@@z ]]\n", { V = "x" }, { escape = { z = { method = "callback", callback = 42 } } })
      end, "Callback must be callable")
    end)
  end)

  describe("M.render (file -> file)", function()
    it("writes the rendered file and returns the output path", function()
      local tmpl = tmpwrite('"v":"--[[ @@V@@ ]]",\n')
      local out = os.tmpname(); tmpfiles[#tmpfiles + 1] = out
      local ret = T.render(tmpl, out, { V = "5.2.2" })
      assert.are.equal(out, ret)
      local f = assert(io.open(out, "rb")); local got = f:read("*a"); f:close()
      assert.are.equal('"v":"5.2.2",\n', got)
    end)
  end)

  describe("render_string / render parity", function()
    it("emits the trailing line of an un-terminated template", function()
      assert.are.equal("first\nlast-no-nl\n", rs("first\nlast-no-nl", {}))
    end)

    it("round-trips a newline-terminated template", function()
      assert.are.equal("a\nb\n", rs("a\nb\n", {}))
    end)
  end)

  -- Acceptance spec for multi-marker support. These define the intended
  -- behaviour and are RED against the current single-marker implementation
  -- (only the first marker on a line is substituted today). They go green once
  -- the render core substitutes every marker on a line. Tagged #multimarker so
  -- they can be run in isolation (`busted --tags=multimarker`) or excluded from
  -- CI (`busted --exclude-tags=multimarker`) until the feature lands.
  describe("multiple markers per line #multimarker", function()
    it("substitutes two inline markers on one line", function()
      assert.are.equal('{"x":1, "y":2}\n',
        rs('{"x":--[[ @@X@@ ]], "y":--[[ @@Y@@ ]]}\n', { X = "1", Y = "2" }))
    end)

    it("substitutes three markers (assembled value)", function()
      assert.are.equal("v=5.2.1\n",
        rs("v=--[[ @@MAJ@@ ]].--[[ @@MIN@@ ]].--[[ @@PATCH@@ ]]\n",
          { MAJ = "5", MIN = "2", PATCH = "1" }))
    end)

    it("substitutes adjacent markers with no separator", function()
      assert.are.equal("ab\n", rs("--[[ @@A@@ ]]--[[ @@B@@ ]]\n", { A = "a", B = "b" }))
    end)

    it("preserves text before, between, and after markers", function()
      assert.are.equal("pre a mid b post\n",
        rs("pre --[[ @@A@@ ]] mid --[[ @@B@@ ]] post\n", { A = "a", B = "b" }))
    end)

    it("applies per-marker escaping independently", function()
      assert.are.equal('"a":"x\\"", "b":"y\\""\n',
        rs('"a":"--[[ j@@A@@j ]]", "b":"--[[ j@@B@@j ]]"\n',
          { A = 'x"', B = 'y"' },
          { escape = { j = { method = "prefix", prefix = "\\", characters = '"' } } }))
    end)

    it("mixes an escaped and a plain marker on one line", function()
      assert.are.equal('raw=a" esc=b\\"\n',
        rs('raw=--[[ @@A@@ ]] esc=--[[ j@@B@@j ]]\n',
          { A = 'a"', B = 'b"' },
          { escape = { j = { method = "prefix", prefix = "\\", characters = '"' } } }))
    end)

    it("still errors on an unknown marker among known ones (default policy)", function()
      raises(function()
        rs("--[[ @@A@@ ]] --[[ @@NOPE@@ ]]\n", { A = "a" })
      end, "Unknown template var: NOPE")
    end)

    it("applies the undefined policy per marker", function()
      assert.are.equal("a= b=2\n",
        rs("a=--[[ @@MISSING@@ ]] b=--[[ @@B@@ ]]\n", { B = "2" },
          { undefined_policy = { action = "quiet", value = "empty" } }))
    end)

    -- Regression guard: a lone marker must keep block-expanding once the core
    -- is rewritten to handle several markers per line.
    it("does not break single-marker block expansion", function()
      assert.are.equal("  a\n  b\n", rs("  --[[ @@A@@ ]]\n", { A = { "a", "b" } }))
    end)

    -- Two markers separated only by whitespace are both inline. The naive
    -- per-match block heuristic misreads the second marker's all-space prefix
    -- as a block indent; this pins the inline result.
    it("renders two space-separated markers inline", function()
      assert.are.equal("a   b\n", rs("--[[ @@A@@ ]]   --[[ @@B@@ ]]\n", { A = "a", B = "b" }))
    end)

    -- A line with more than one marker is inline, never a block -- even when
    -- every marker is whitespace-prefixed. Trailing text after the last marker
    -- must be preserved, not rejected as "trailing text after block" (that rule
    -- is for a single lone marker only). Guards against the whitespace-only
    -- block heuristic over-firing on multi-marker lines.
    it("keeps trailing text after space-separated markers", function()
      assert.are.equal("a btrailing\n",
        rs("--[[ @@A@@ ]] --[[ @@B@@ ]]trailing\n", { A = "a", B = "b" }))
    end)

    it("keeps trailing text after adjacent markers", function()
      assert.are.equal("abx\n",
        rs("--[[ @@A@@ ]]--[[ @@B@@ ]]x\n", { A = "a", B = "b" }))
    end)
  end)

  -- Block classification depends only on a marker being alone on its line, not
  -- on the indent amount: column 0 expands just like any indented marker.
  describe("block classification #multimarker", function()
    it("block-expands a lone marker at column 0", function()
      assert.are.equal("a\nb\n", rs("--[[ @@A@@ ]]\n", { A = { "a", "b" } }))
    end)

    it("still expands an indented lone marker", function()
      assert.are.equal("  a\n  b\n", rs("  --[[ @@A@@ ]]\n", { A = { "a", "b" } }))
    end)
  end)

  -- Trailing text after a block marker.
  describe("block trailing text #multimarker", function()
    it("errors by default", function()
      raises(function() rs("  --[[ @@A@@ ]] trailing\n", { A = { "x", "y" } }) end,
        "Trailing text after block: ' trailing'")
    end)

    it("appends trailing text to the last line when allowed", function()
      assert.are.equal("  x\n  y trailing\n",
        rs("  --[[ @@A@@ ]] trailing\n", { A = { "x", "y" } },
          { allow_multiblock_trailing = true }))
    end)

    it("allows a clean block when the flag is set (no trailing text)", function()
      assert.are.equal("  x\n  y\n",
        rs("  --[[ @@A@@ ]]\n", { A = { "x", "y" } },
          { allow_multiblock_trailing = true }))
    end)
  end)

  -- Scanner edge cases around "--[[" that does not form a valid marker. The
  -- scanner must advance past every false start; a bad rescan stride loops
  -- forever. Bounded so a regression fails instead of hanging. Tagged #scanner.
  describe("stray '--[[' sequences #scanner", function()
    it("leaves a line with two non-marker '--[[' unchanged", function()
      local tmpl = "x --[[ --[[ y\n"
      assert.are.equal(tmpl, rs_bounded(tmpl, { V = "1" }))
    end)

    it("still substitutes a real marker after a stray '--[['", function()
      assert.are.equal("--[[ oops 5\n",
        rs_bounded("--[[ oops --[[ @@V@@ ]]\n", { V = "5" }))
    end)

    it("leaves a lone non-marker '--[[' unchanged", function()
      local tmpl = 'log("--[[ not a marker")\n'
      assert.are.equal(tmpl, rs_bounded(tmpl, {}))
    end)
  end)
end)
