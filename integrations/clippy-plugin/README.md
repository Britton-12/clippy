# clippy (Claude Code plugin)

Registers the [`clippy-mcp`](../clippy-mcp) server and adds slash commands so Claude Code can drive the Clippy macOS clipboard manager.

## Layout

```
clippy-plugin/
├── .claude-plugin/plugin.json   # manifest (name, version, description)
├── .mcp.json                    # registers the clippy MCP server
└── commands/
    ├── clippy-search.md         # /clippy-search <terms>
    ├── clippy-add.md            # /clippy-add <text>
    └── clippy-recent.md         # /clippy-recent [count]
```

## Prerequisites

Build the MCP server first (it must sit next to this plugin under `integrations/`):

```bash
cd ../clippy-mcp
npm install
npm run build
```

`.mcp.json` points at `${CLAUDE_PLUGIN_ROOT}/../clippy-mcp/build/index.js`, which resolves when `clippy-mcp` and `clippy-plugin` are siblings (as they are in this repo). If you relocate the plugin, edit `.mcp.json` to an absolute path to `clippy-mcp/build/index.js`, or set `CLIPPY_DB_PATH` and point at an installed copy.

## Commands

| Command | Tool used |
|---|---|
| `/clippy-search <terms>` | `clippy_search` |
| `/clippy-add <text>` | `clippy_add` |
| `/clippy-recent [count]` | `clippy_list_recent` |

The plugin also exposes every `clippy_*` tool (get, delete, categories, set/create category) for Claude to call directly. See [`../clippy-mcp/README.md`](../clippy-mcp/README.md) for the full tool list and the live-refresh caveat.
