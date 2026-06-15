// Smoke test: spawn the built server against a throwaway DB, drive it over
// stdio JSON-RPC. Lists tools, then proves an add -> search round-trip and a
// category round-trip. Never touches the user's real database.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, "..");

// 1. Build a temp DB with the derived schema.
const dir = mkdtempSync(path.join(tmpdir(), "clippy-mcp-test-"));
const dbPath = path.join(dir, "clippy.sqlite");
const schema = readFileSync(path.join(here, "schema.sql"), "utf8");
const seed = new DatabaseSync(dbPath);
seed.exec(schema);
// Seed one category so set_category has a target.
seed
  .prepare(
    `INSERT INTO category (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
     VALUES ('Pinned', '#FF9500', 'symbol', 'pin.fill', 0, 1, '2026-01-01 00:00:00.000')`,
  )
  .run();
seed.close();

// 2. Spawn the server.
const child = spawn("node", [path.join(root, "build", "index.mjs")], {
  env: { ...process.env, CLIPPY_DB_PATH: dbPath },
  stdio: ["pipe", "pipe", "pipe"],
});
child.stderr.on("data", (d) => process.stderr.write(`[server] ${d}`));

let buf = "";
const pending = new Map();
child.stdout.on("data", (chunk) => {
  buf += chunk.toString();
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    if (msg.id !== undefined && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  }
});

let nextId = 1;
function rpc(method, params) {
  const id = nextId++;
  return new Promise((resolve) => {
    pending.set(id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}
function notify(method, params) {
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
}

function unwrap(resp) {
  return JSON.parse(resp.result.content[0].text);
}

const fail = (m) => {
  console.error("FAIL:", m);
  child.kill();
  process.exit(1);
};

try {
  // initialize handshake
  await rpc("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "smoke", version: "0.0.0" },
  });
  notify("notifications/initialized", {});

  // tools/list
  const list = await rpc("tools/list", {});
  const names = list.result.tools.map((t) => t.name).sort();
  console.log("TOOLS:", names.join(", "));
  const expected = [
    "clippy_add",
    "clippy_create_category",
    "clippy_delete",
    "clippy_get",
    "clippy_list_categories",
    "clippy_list_recent",
    "clippy_search",
    "clippy_set_category",
  ];
  for (const e of expected) {
    if (!names.includes(e)) fail(`missing tool ${e}`);
  }

  // add -> search round-trip
  const added = unwrap(
    await rpc("tools/call", {
      name: "clippy_add",
      arguments: { text: "hello kangaroo from clippy mcp", title: "Smoke Note" },
    }),
  );
  console.log("ADD ->", JSON.stringify(added));
  if (!added.id) fail("add returned no id");

  const found = unwrap(
    await rpc("tools/call", {
      name: "clippy_search",
      arguments: { query: "kangaroo" },
    }),
  );
  console.log("SEARCH ->", JSON.stringify(found));
  const hit = found.results.find((r) => r.id === added.id);
  if (!hit) fail("search did not return the added clip (FTS sync broken)");
  if (hit.title !== "Smoke Note") fail("title not surfaced");

  // get full clip
  const got = unwrap(
    await rpc("tools/call", { name: "clippy_get", arguments: { id: added.id } }),
  );
  if (got.contentText !== "hello kangaroo from clippy mcp")
    fail("get returned wrong contentText");
  console.log("GET ->", JSON.stringify({ id: got.id, contentText: got.contentText }));

  // category round-trip
  const cats = unwrap(
    await rpc("tools/call", { name: "clippy_list_categories", arguments: {} }),
  );
  console.log("CATEGORIES ->", JSON.stringify(cats.categories));
  const newCat = unwrap(
    await rpc("tools/call", {
      name: "clippy_create_category",
      arguments: { name: "MCP Test", colorHex: "30B0C7" },
    }),
  );
  console.log("CREATE CATEGORY ->", JSON.stringify(newCat));
  await rpc("tools/call", {
    name: "clippy_set_category",
    arguments: { clipID: added.id, categoryID: newCat.id, member: true },
  });
  const afterMember = unwrap(
    await rpc("tools/call", { name: "clippy_get", arguments: { id: added.id } }),
  );
  const inCat = afterMember.categories.some((c) => c.id === newCat.id);
  if (!inCat) fail("set_category did not attach the clip");
  console.log("MEMBERSHIP ->", JSON.stringify(afterMember.categories));

  // delete -> search empty
  await rpc("tools/call", {
    name: "clippy_delete",
    arguments: { id: added.id },
  });
  const afterDelete = unwrap(
    await rpc("tools/call", {
      name: "clippy_search",
      arguments: { query: "kangaroo" },
    }),
  );
  if (afterDelete.results.some((r) => r.id === added.id))
    fail("delete did not remove clip from FTS");
  console.log("AFTER DELETE search ->", JSON.stringify(afterDelete.results));

  console.log("\nALL CHECKS PASSED");
  child.kill();
  process.exit(0);
} catch (err) {
  fail(err && err.stack ? err.stack : String(err));
}
