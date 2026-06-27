# simple-template

A small, pure-Lua templating engine (5.1–5.4 + LuaJIT) with **no control flow** and
**first-class escaping**. Markers are embedded as inert comments / string values, so a
template stays valid in its own language until you render it.

```lua
local T = require("simple-template")

T.render_string('"version": "--[[ @@V@@ ]]",\n', { V = "5.2.2" })
--> '"version": "5.2.2",\n'
```

The design choice is deliberate: there are no `if`/`for` constructs in templates. Any logic
lives in Lua — you compute the values (or supply a callback) and the template just places
them. This keeps templates trivially readable and impossible to turn into a second program.

## Install

```sh
luarocks install simple-template
```

## The marker

A marker looks like a Lua block comment:

```
--[[ @@NAME@@ ]]
```

Because that is also a valid string *value* in JSON/YAML/TOML, the template file parses
and lints in its target language before rendering:

```json
{ "version": "--[[ @@V@@ ]]" }
```

Rules:

- `NAME` may be any run of non-whitespace, non-`@` characters.
- At most **one** space may separate the comment brackets from the `@@`. To emit a line
  that merely *looks* like a marker, drop one `@`.
- An optional **escape name** (letters) may flank the marker — see [Escaping](#escaping).
  The two sides must match: `--[[ json@@DESC@@json ]]`.

### Inline vs. block

- **Inline** — a marker with other text on its line is replaced in place; surrounding text
  is preserved. A multi-line value uses only its first line.
- **Block** — a marker alone on its (indented) line expands to *every* line of its value,
  each re-indented to the marker's column. Trailing text after a block marker is an error.

```lua
T.render_string("  --[[ @@ITEMS@@ ]]\n", { ITEMS = { "a", "b" } })
--> "  a\n  b\n"
```

## API

### `render(template_path, out_path, sources [, opt])` → `out_path`
Renders a file to a file. The write is **atomic** (temp file + rename), so a failed render
never leaves a half-written output. Returns the output path.

### `render_string(template, sources [, opt])` → `string`
Renders an in-memory template and returns the result. Behaviourally identical to `render`,
including handling of a template whose final line has no trailing newline.

`sources` maps each marker name to a value (see below). `opt` is optional:

```lua
opt = {
  escape           = { <name> = <rule|rule-list>, ... },
  undefined_policy = { action = "error"|"quiet"|"warn", value = "empty"|"keep"|<callable> },
}
```

## Sources

| Source | Result |
| --- | --- |
| `"text"` | a literal value (single line) |
| `T.as_string(v)` | forces `v` (string/number/`__tostring`) to a literal |
| `T.as_lines(s)` | splits `s` on newlines into block lines |
| `T.as_path(path)` | the file's contents, line by line |
| `{ "a", "b" }` | an explicit array of lines |
| `T.as_callback(fn)` | `fn(start, marker, rest, lesc, esc_rules, line)` → array of lines, computed at render time |

```lua
T.render("info.tmpl.json", "info.json", {
  NAME    = "my-mod",
  VERSION = "5.2.2",
  AUTHORS = { '"alice",', '"bob"' },
  NOTES   = T.as_path("changelog-excerpt.txt"),
})
```

## Escaping

Each escape rule is `{ method = ..., characters = ..., ... }`. `characters` lists the bytes
to escape (ASCII only). Reference a rule by putting its name on both sides of a marker.

| `method` | extra field | each listed char becomes |
| --- | --- | --- |
| `prefix` | `prefix` | `prefix .. char` |
| `double` | — | `char .. char` |
| `surround` | `surround` | `surround .. char .. surround` |
| `hexcode` | `prefix` | `prefix .. UPPER_HEX_BYTE` |
| `callback` | `callback` | `callback(text, rule)` (function or `__call` table) |

A rule value may also be an **array of rules**, applied in order. The same escaping is
applied to every line of a block.

```lua
-- Make arbitrary text safe inside a JSON string:
T.render_string('"desc": "--[[ json@@D@@json ]]",\n',
  { D = 'he said "hi"\\bye' },
  { escape = { json = { method = "prefix", prefix = "\\", characters = '"\\' } } })
--> '"desc": "he said \\"hi\\"\\\\bye",\n'
```

## Undefined variables

By default an unknown marker is an error. `opt.undefined_policy` changes that:

- `action` — `"error"` (default), `"warn"` (print + continue), or `"quiet"`.
- `value` — what to substitute when not erroring: `"empty"` (drop the marker, keep
  surrounding text), `"keep"` (leave the original line), or a callable returning lines.

```lua
T.render_string("x=--[[ @@MISSING@@ ]]y\n", {},
  { undefined_policy = { action = "quiet", value = "empty" } })
--> "x=y\n"
```

## Limitations

- **One marker per line.** Only the first marker on a line is substituted today; a second
  marker is currently emitted verbatim. Put one value per line, or pre-assemble the value
  in Lua, until multi-marker support lands.
- **No control flow** — by design. Use `as_callback` / arrays for anything dynamic.
- **ASCII escaping only** — escaping non-ASCII bytes is out of scope.

## Development

```sh
luarocks install busted
busted              # run the spec
luarocks lint *.rockspec
```

## License

MIT © t0suj4
