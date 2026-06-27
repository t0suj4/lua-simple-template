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

-- Capture the message of an expected error.
local function errmsg(fn)
  local ok, e = pcall(fn)
  assert.is_false(ok, "expected the call to raise an error")
  return tostring(e)
end
-- Plain-substring match (error messages may carry a file:line prefix).
local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
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
      assert.is_true(contains(errmsg(function() rs("n=--[[ @@N@@ ]]\n", { N = 42 }) end),
        "Source must be a string or a table"))
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
          rs("v=--[[ @@C@@ ]]\n", { C = T.as_callback(function(_, marker) return { "DYN:" .. marker } end) }))
      end)

      it("can return a multi-line block", function()
        assert.are.equal("  a\n  b\n",
          rs("  --[[ @@C@@ ]]\n", { C = T.as_callback(function() return { "a", "b" } end) }))
      end)

      it("rejects a non-table return", function()
        assert.is_true(contains(errmsg(function()
          rs("v=--[[ @@C@@ ]]\n", { C = T.as_callback(function() return "oops" end) })
        end), "callback should return a table"))
      end)

      it("rejects a non-callable constructor argument", function()
        assert.is_true(contains(errmsg(function() T.as_callback(42) end), "Expected callable"))
      end)
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
      assert.is_true(contains(errmsg(function() rs("--[[ @@NOPE@@ ]]\n", {}) end),
        "Unknown template var: NOPE"))
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
        { undefined_policy = { action = "quiet", value = function(_, m) return { "fb:" .. m } end } }))
    end)

    it("rejects an unknown action", function()
      assert.is_true(contains(errmsg(function()
        rs("--[[ @@N@@ ]]\n", {}, { undefined_policy = { action = "bogus" } })
      end), "undefined_policy.action"))
    end)

    it("rejects an unknown value", function()
      assert.is_true(contains(errmsg(function()
        rs("--[[ @@N@@ ]]\n", {}, { undefined_policy = { action = "quiet", value = "bogus" } })
      end), "value"))
    end)
  end)

  describe("error paths", function()
    it("flags an escape-marker mismatch", function()
      assert.is_true(contains(errmsg(function()
        rs("--[[ a@@V@@b ]]\n", { V = "x" }, { escape = { a = { method = "double", characters = "x" } } })
      end), "Escape marker differs"))
    end)

    it("flags an unknown escape rule", function()
      assert.is_true(contains(errmsg(function() rs('"--[[ zz@@V@@zz ]]"\n', { V = "x" }) end),
        "Unknown escape rule zz"))
    end)

    it("forbids trailing text after a block marker", function()
      assert.is_true(contains(errmsg(function() rs("  --[[ @@A@@ ]]x\n", { A = { "a", "b" } }) end),
        "Trailing text after block"))
    end)

    it("forbids more than one separating space", function()
      assert.is_true(contains(errmsg(function() rs("--[[  @@V@@ ]]\n", { V = "x" }) end),
        "At most 1 separating space"))
    end)

    it("rejects a non-callable escape callback", function()
      assert.is_true(contains(errmsg(function()
        rs("v=--[[ z@@V@@z ]]\n", { V = "x" }, { escape = { z = { method = "callback", callback = 42 } } })
      end), "Callback must be callable"))
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
      assert.is_true(contains(errmsg(function()
        rs("--[[ @@A@@ ]] --[[ @@NOPE@@ ]]\n", { A = "a" })
      end), "Unknown template var: NOPE"))
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
      assert.is_true(contains(
        errmsg(function() rs("  --[[ @@A@@ ]] trailing\n", { A = { "x", "y" } }) end),
        "Trailing text after block: ' trailing'"))
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
end)
