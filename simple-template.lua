-- Simple templating engine
--
-- Copyright 2025 t0suj4
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

function M.as_callback(callback)
    if not is_callable(callback) then
        error("Expected callable type, got " .. type(callback), 2)
    end
    return {AS_CALLBACK, callback}
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

local function apply_escaping(text, rules)
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

local UNDEFINED_POLICY_DEFAULTS = {action = "error"}

local function do_render(line_iter, sink, loaded_vars, opt, errlevel)
    local escape_rules = opt.escape_rules
    local undefined_policy = opt.undefined_policy or UNDEFINED_POLICY_DEFAULTS
    validate_undefined_policy(undefined_policy, errlevel + 1)
    local allow_multiblock_trailing = opt.allow_multiblock_trailing or false

    local errlevel2 = errlevel + 2
    for line in line_iter do
        local pattern = "((.-)%-%-%[%[( *)(%a*)@@([^%s@]+)@@(%a*)( *)%]%])"
        local w = line:gsub(pattern, function(chunk, start, lspaces, lesc, marker, resc, rspaces)
            local replacement = loaded_vars[marker]
            local esc_rules = escape_rules[lesc]
            if lspaces and lspaces:len() > 1 or rspaces and rspaces:len() > 1 then
                error("At most 1 separating space allowed, to disable pattern delete a @", errlevel2)
            elseif lesc ~= resc then
                error("Escape marker differs '" .. lesc .. "' ~= '" .. resc .. "'", errlevel2)
            elseif lesc ~= "" and not esc_rules then
                error("Unknown escape rule " .. lesc, errlevel2)
            end
            if not replacement then
                if undefined_policy.action == "error" then
                    error("Unknown template var: " .. marker, errlevel2)
                elseif undefined_policy.action == "warn" then
                    print("Unknown template var: " .. marker)
                elseif undefined_policy.action == "quiet" then
                    -- quiet
                end
                if undefined_policy.value == "empty" then
                    return start
                elseif undefined_policy.value == "keep" then
                    return chunk
                else
                    -- callback
                    replacement = undefined_policy.value(start, marker, lesc, esc_rules, chunk, line)
                    if type(replacement) ~= "table" then
                        error("Novar callback should return a table", errlevel2)
                    end
                end
            end
            if replacement then
                if replacement[1] == AS_CALLBACK then
                    replacement = replacement[2](start, marker, lesc, esc_rules, chunk, line)
                    -- Not type checking contents here
                    if type(replacement) ~= "table" then
                        error("Var callback should return a table", errlevel2)
                    end
                end

                if #replacement == 1 or start:find("%S") ~= nil then
                    if #replacement > 1 then
                        error("Got " .. #replacement .. " lines in an inline expansion", errlevel2) 
                    elseif lesc ~= "" then
                        return start .. apply_escaping(replacement[1], esc_rules)
                    else
                        return start .. replacement[1]
                    end
                else
                    local parts = {}
                    if not allow_multiblock_trailing and line:len() > chunk:len() then
                        error("Trailing text after block: '" .. line:sub(chunk:len() + 1) .. "'", errlevel2)
                    end
                    if lesc ~= "" then
                        for _, rep in ipairs(replacement) do
                            parts[#parts + 1] = start .. apply_escaping(rep, esc_rules)
                        end
                    else
                        for _, rep in ipairs(replacement) do
                            parts[#parts + 1] = start .. rep
                        end
                    end
                    return table.concat(parts, "\n")
                end
            end
        end)
        sink:write(w, "\n")
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
