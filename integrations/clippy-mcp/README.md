# clippy-mcp

An MCP server that lets Claude read and write the [Clippy](../../) macOS clipboard manager's data. It talks directly to Clippy's GRDB/SQLite database (no app API needed).

See [SCHEMA.md](./SCHEMA.md) for the exact tables, columns, FTS setup, and file:line citations the server was built from.

## Tools

| Tool | Purpose |
|---|---|
| `clippy_search(query, limit?)` | FTS5 search. Returns id, title, preview, kind, createdAt, categories. |
| `clippy_list_recent(limit?)` | Most recent clips, newest first. |
| `clippy_get(id)` | One clip in full, incl. contentText and (for images) media + thumb file paths. |
| `clippy_add(text, title?)` | Insert a new plain-text clip. |
| `clippy_delete(id)` | Delete a clip. |
| `clippy_list_categories()` | All categories: id, name, colorHex, icon, isStarter. |
| `clippy_set_category(clipID, categoryID, member)` | Add/remove a clip's category membership. |
| `clippy_create_category(name, colorHex?, iconKind?, iconValue?)` | Create a category. |

The FTS index (`clips_fts`) is kept in sync automatically by Clippy's own database triggers, so `clippy_add` / `clippy_delete` need no manual FTS maintenance.

## Prerequisites

- Node.js 22.13 or newer. The server uses Node's built-in `node:sqlite` module, which is available unflagged from v22.13, so there are no native dependencies to compile or ship.
- Clippy installed and launched at least once (so the database exists). The default DB path is `~/Library/Application Support/Clippy/clippy.sqlite`.

## Build

```bash
cd integrations/clippy-mcp
npm install
npm run build
```

This bundles everything into a single `build/index.mjs` (the server entry point) via esbuild. `npm test` builds, then runs an offline smoke test against a throwaway database. The Clippy app ships this same file inside its bundle at `Clippy.app/Contents/Resources/clippy-mcp/index.mjs` and launches it on demand, so installed users do not need to build anything.

## Configuration

The server resolves the database at `~/Library/Application Support/Clippy/clippy.sqlite`. Override with the `CLIPPY_DB_PATH` environment variable.

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "clippy": {
      "command": "node",
      "args": ["/Users/jerry/Downloads/clippy/integrations/clippy-mcp/build/index.mjs"]
    }
  }
}
```

### Claude Code (project `.mcp.json`)

Add to a `.mcp.json` at your project root:

```json
{
  "mcpServers": {
    "clippy": {
      "command": "node",
      "args": ["/Users/jerry/Downloads/clippy/integrations/clippy-mcp/build/index.mjs"]
    }
  }
}
```

Use an absolute path to `build/index.mjs`. To point at a non-default database, add `"env": { "CLIPPY_DB_PATH": "/path/to/clippy.sqlite" }`.

## Live-refresh caveat

The running Clippy app holds its own SQLite connection. Writes made by this server (e.g. `clippy_add`) land in the database immediately, but the app's in-memory list will not show them until the app next reloads from disk, which happens on its next internal change (a new capture, an edit) or on relaunch. Reads through this server always reflect the current on-disk state.

## Safety

- All SQL uses parameterized statements; user input is never interpolated into SQL.
- WAL mode is set on connect to cooperate with the app's connection.
- No secrets are stored in code.
