-- Simple templating engine
--
-- Copyright 2025-2026 t0suj4
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the “Software”), to
-- deal in the Software without restriction, including without limitation the
-- rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
-- sell copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
-- IN THE SOFTWARE.

local M = {}

local AS_STRING = {"AS_STRING"}
local AS_PATH = {"AS_PATH"}
local AS_CALLBACK = {"AS_CALLBACK"}

---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack

local function load_file(file)
    local lines = {}
    for line in file:lines() do
        lines[#lines + 1] = line
    end
    return lines
end

local function is_stringable(val)
    local t = type(val)
    if t ~= "string" and t ~= "number" then
        local mt = getmetatable(val)
        if type(mt) ~= "table" or type(mt.__tostring) ~= "function" then
            return false
        end
    end
    return true
end

local function is_callable(val, depth)
    depth = depth or 0
    local t = type(val)
    if t ~= "function" then
        if depth > 50 then
            return false
        end
        local mt = getmetatable(val)
        if type(mt) ~= "table" then
            return false
        end
        return is_callable(mt.__call, depth + 1)
    end
    return true
end

local function load_source(source, errlevel)
    if type(source) == "string" then
        return {source}
    elseif type(source) == "table" then
        assert(#source > 0, "Table source must have at least one string", errlevel)
        if source[1] == AS_PATH then
            local f = assert(io.open(source[2], "rb"))
            local content = load_file(f)
            f:close()
            return content
        elseif source[1] == AS_STRING then
            return {source[2]}
        elseif source[1] == AS_CALLBACK then
            return source
        else
            for _, str in ipairs(source) do
                assert(is_stringable(str), "Table source must be array of stringables", errlevel)
            end
            return source
        end
    else
        error("Source must be a string or a table", errlevel)
    end
end

local function each_line(s)
    local pos, len = 1, #s
    return function()
        if pos > len then
            return nil
        end
        local nl = s:find("\n", pos, true)
        if nl then
            local l = s:sub(pos, nl - 1)
            pos = nl + 1
            return l
        end
        local l = s:sub(pos)
        pos = len + 1
        return l
    end
end

function M.as_path(source)
    if type(source) ~= "string" then
        error("Expected string, got " .. type(source), 2)
    end
    return {AS_PATH, source}
end

function M.as_string(source)
    if not is_stringable(source) then
        error("Expected stringable type, got " .. type(source), 2)
    end
    return {AS_STRING, tostring(source)}
end

function M.as_lines(source)
    if not is_stringable(source) then
        error("Expected stringable type, got " .. type(source), 2)
    end
    local lines = {}
    for line in each_line(tostring(source)) do
        lines[#lines + 1] = line
    end
    return lines
end

local function as_callback(callback, source)
    if not is_callable(callback) then
        error("Expected callable type, got " .. type(callback), 2)
    end
    return {AS_CALLBACK, callback, source}
end

function M.as_callback(callback)
    return as_callback(callback, "Var")
end

local function create_escape_table(rule, errlevel)
    local tbl = {}
    local characters = rule.characters
    assert(type(rule.method) == "string", "rule.method must be string: " .. type(rule.method), errlevel)
    if characters:find("[\128-\255]") then
        error("Escaping supports only ASCII range '" .. characters .. "'", errlevel)
    elseif rule.method == "prefix" then
        assert(type(rule.prefix) == "string", "rule.prefix must be string: " .. type(rule.prefix), errlevel)
        local prefix = rule.prefix
        for char in characters:gmatch(".") do
            tbl[char] = prefix .. char
        end
    elseif rule.method == "double" then
        for char in characters:gmatch(".") do
            tbl[char] = char .. char
        end
    elseif rule.method == "hexcode" then
        assert(type(rule.prefix) == "string", "rule.prefix must be string: " .. type(rule.prefix), errlevel)
        local prefix = rule.prefix
        for char in characters:gmatch(".") do
            tbl[char] = prefix .. string.format("%02X", char:byte())
        end
    elseif rule.method == "surround" then
        assert(type(rule.surround) == "string", "rule.surround must be string: " .. type(rule.surround), errlevel)
        local surround = rule.surround
        for char in characters:gmatch(".") do
            tbl[char] = surround .. char .. surround
        end
    else
        error("Unsupported method: " .. rule.method)
    end
    return tbl
end

local ESCAPE_LUA_PATTERN_TABLE = {
    ["["] = "%[",
    ["]"] = "%]",
    ["("] = "%(",
    [")"] = "%)",
    ["."] = "%.",
    ["+"] = "%+",
    ["-"] = "%-",
    ["*"] = "%*",
    ["%"] = "%%",
    ["?"] = "%?",
    ["$"] = "%$",
    ["^"] = "%^",
}

local function escape_lua_pattern(text)
    return text:gsub("([%[%]%(%)%-%.%+%*%^%$%%])", ESCAPE_LUA_PATTERN_TABLE)
end

local function process_escape_rule(rule, errlevel)
    assert(rule.method, "Rule method is missing", errlevel)
    if rule.method == "callback" then
        assert(is_callable(rule.callback), "Callback must be callable: " .. type(rule.callback), errlevel)
        local cb = rule.callback
        return function(text)
            return cb(text, rule)
        end
    end

    local tbl = create_escape_table(rule, errlevel + 1)
    local char_pat = "[" .. escape_lua_pattern(rule.characters) .. "]"
    return function(text)
        return text:gsub(char_pat, tbl)
    end
end


local function load_escape_rules(escape, errlevel)
    if type(escape) ~= "table" then
        error("Escape rules must be a table", errlevel)
    end
    if escape[1] then
        local rules = {}
        for _, rule in ipairs(escape) do
            rules[#rules + 1] = process_escape_rule(rule, errlevel + 1)
        end
        return rules
    end
    return {process_escape_rule(escape, errlevel + 1)}
end

local ESCAPE_PASSTHROUGH = { function(text) return text end }

local function apply_escaping(text, rules)
    if rules == ESCAPE_PASSTHROUGH then
        return text
    end
    for _, rule in ipairs(rules) do
        text = rule(text)
    end
    return text
end

local function validate_undefined_policy(tbl, errlevel)
    if type(tbl) ~= "table" then
        error("undefined_policy should be a table", errlevel)
    end
    if tbl.action == "error" then
        return
    end
    if tbl.action ~= "quiet" and tbl.action ~= "warn" then
        error("undefined_policy.action can be one of: \"error\", \"quiet\", \"warn\"", errlevel)
    end
    if tbl.value ~= "empty" and tbl.value ~= "keep" and not is_callable(tbl.value) then
        error("undefined_police.value can be one of: \"empty\", \"keep\", callable", errlevel)
    end
end

local UNDEFINED_POLICY_DEFAULTS = {action = "error", value = "empty"}

local TEMPLATE_PATTERN = "^%-%-%[%[( *)(%a*)@@([^%s@]+)@@(%a*)( *)%]%]()"

local function to_undefined_policy_cb(value)
    local cb
    if value == "empty" then
        cb = function()
            return {""}
        end
    elseif value == "keep" then
        cb = function(_, _, _, _, _ ,_, snippet)
            return {snippet}
        end
    else
        cb = value
    end
    return as_callback(cb, "Undefined policy")
end

local function make_ctx(ctx_raw)
    local line = ctx_raw[1]
    return {
        line = line,
        start = line:sub(ctx_raw[2], ctx_raw[3] - 1),
        chunk = line:sub(ctx_raw[2], ctx_raw[4] - 1),
        snippet = line:sub(ctx_raw[3], ctx_raw[4] - 1),
    }
end

local function do_render(line_iter, sink, loaded_vars, opt, errlevel)
    local escape_rules = opt.escape_rules
    local undefined_policy = opt.undefined_policy or UNDEFINED_POLICY_DEFAULTS
    validate_undefined_policy(undefined_policy, errlevel + 1)
    local undef_policy = {
        action = undefined_policy.action,
        value = to_undefined_policy_cb(undefined_policy.value),
    }
    local allow_multiblock_trailing = opt.allow_multiblock_trailing or false

    local errlevel2 = errlevel + 2

    local function resolve_escape(esc)
        if esc == "" then
            return ESCAPE_PASSTHROUGH
        else
            return escape_rules[esc] or error("Unknown escape rule " .. esc, errlevel2)
        end
    end

    local function resolve_callbacks(replacement, marker, esc, esc_rules, ctx, limit)
        if limit <= 0 then
            error("Got callback chain too deep", errlevel2)
        end
        if replacement[1] ~= AS_CALLBACK then
            return replacement
        end
        limit = limit - 1
        local rep = replacement[2](ctx.start, marker, esc, esc_rules, ctx.chunk, ctx.line, ctx.snippet)
        -- Not type checking contents here
        if type(rep) ~= "table" then
            error(replacement[3] .. " callback should return a table", errlevel2)
        end
        return resolve_callbacks(rep, marker, esc, esc_rules, ctx, limit - 1)
    end

    local function resolve_vars(marker)
        local replacement = loaded_vars[marker]

        if not replacement then
            if undef_policy.action == "error" then
                error("Unknown template var: " .. marker, errlevel2)
            elseif undef_policy.action == "warn" then
                print("Unknown template var: " .. marker)
            -- elseif undef_policy.action == "quiet" then
                -- quiet
            end
            replacement = undef_policy.value
        end

        return replacement
    end

    local function substitute(replacement, esc_rules, block)
        if block then
            local parts = {}
            for _, rep in ipairs(replacement) do
                parts[#parts + 1] = apply_escaping(rep, esc_rules)
            end
            return parts
        else
            return {apply_escaping(replacement[1], esc_rules)}
        end
    end

    local function resolve_values(match)
        local esc, marker, start, ctx_raw = unpack(match)
        local esc_rules = resolve_escape(esc)
        local replacement = resolve_vars(marker)
        if replacement[1] == AS_CALLBACK then
            local ctx = make_ctx(ctx_raw)
            replacement = resolve_callbacks(replacement, marker, esc, esc_rules, ctx, 50)
        end
        local block = #replacement ~= 1 and start:find("%S") == nil
        if not block and #replacement > 1 then
            error("Got " .. #replacement .. " lines in an inline expansion", errlevel)
        end
        local values = substitute(replacement, esc_rules, block)

        return values, block
    end

    local pos, begin, line
    local ctx_raw = {false, false, false, false}
    local function next_match(pattern)
        local function scan(pat, at)
            if at >= line:len() then
                return nil
            end
            local lsp, lesc, marker, resc, rsp, endpos = line:match(pat, at)
            if not lsp then
                at = line:find("--[[", at + 4, true)
                if at then
                    return scan(pat, at)
                else
                    return nil
                end
            end
            if lsp:len() > 1 or rsp:len() > 1 then
                error("At most 1 separating space allowed, to disable pattern delete a @", errlevel)
            elseif lesc ~= resc then
                error("Escape marker differs '" .. lesc .. "' ~= '" .. resc .. "'", errlevel)
            end
            ctx_raw[2] = pos
            ctx_raw[3] = at
            ctx_raw[4] = endpos
            local start = line:sub(pos, at - 1)
            at = line:find("--[[", endpos, true)
            pos = endpos
            return at or line:len(), {lesc, marker, start, ctx_raw}
        end
        return scan, pattern, begin
    end
    local function tail()
        return line:sub(pos)
    end

    local function emit(start, values)
        local l = #values
        for i = 1, l do
            sink:write(start)
            sink:write(values[i])
            if i < l then
                sink:write("\n")
            end
        end
    end

    for l in line_iter do
        line = l
        ctx_raw[1] = line
        -- Eliminate n^2 scan
        begin = line:find("--[[", 1, true)
        if not begin then
            sink:write(line, "\n")
        else
            pos = 1
            local line_is_block = false
            for _, m in next_match(TEMPLATE_PATTERN) do
                local values, block = resolve_values(m)
                line_is_block = line_is_block or block
                emit(m[3], values)
            end
            local rest = tail()
            if rest ~= "" and line_is_block and not allow_multiblock_trailing then
                error("Trailing text after block: '" .. rest .. "'", errlevel)
            else
                sink:write(rest, "\n")
            end
        end
    end
end

function M.render(template_path, out_path, sources, opt)
    opt = opt or {}
    local escape = opt.escape or {}

    local errlevel = 2
    local loaded_vars = {}
    for name, src in pairs(sources) do
        loaded_vars[name] = load_source(src, errlevel + 1)
    end

    local escape_rules = {}
    for name, rules in pairs(escape) do
        escape_rules[name] = load_escape_rules(rules, errlevel + 1)
    end
    opt.escape_rules = escape_rules

    local out_write_name = out_path .. ".ttmpl~"
    local out = assert(io.open(out_write_name, "wb"))

    local run_rendering = function()
        do_render(io.lines(template_path), out, loaded_vars, opt, errlevel + 3)
    end

    local cleanup = function(err)
        os.remove(out_write_name)
        return debug.traceback(err, 2)
    end

    local ok, err = xpcall(run_rendering, cleanup)

    out:close()
    if ok then
        os.rename(out_write_name, out_path)
    else
        os.remove(out_write_name)
        error(err, 0)
    end
    return out_path
end

function M.render_string(template, sources, opt)
    opt = opt or {}
    local escape = opt.escape or {}

    local errlevel = 2
    local loaded_vars = {}
    for name, src in pairs(sources) do
        loaded_vars[name] = load_source(src, errlevel + 1)
    end

    local escape_rules = {}
    for name, rules in pairs(escape) do
        escape_rules[name] = load_escape_rules(rules, errlevel + 1)
    end
    opt.escape_rules = escape_rules

    local write = function(this, ...)
        for i = 1, select("#", ...) do
            this.buf[#this.buf + 1] = select(i, ...)
        end
    end

    local sink = {buf = {}, write = write}
    do_render(each_line(template), sink, loaded_vars, opt, errlevel + 1)

    return table.concat(sink.buf, "")
end

return M
