#!/usr/bin/env node
import http from "node:http";
import { randomUUID } from "node:crypto";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import type { IncomingMessage, ServerResponse } from "node:http";
import { zodToJsonSchema } from "zod-to-json-schema";
import type { DatabaseSync } from "node:sqlite";
import { openDatabase, resolveDatabasePath } from "./db.js";
import { tools } from "./tools.js";

// ---------------------------------------------------------------------------
// Bootstrap: open the DB once, fail loud if it is missing.
// ---------------------------------------------------------------------------

const dbPath = resolveDatabasePath();
let db: DatabaseSync;
try {
  db = openDatabase(dbPath);
} catch (err) {
  console.error(
    `clippy-mcp: could not open database at ${dbPath}. ` +
      `Set CLIPPY_DB_PATH or launch Clippy once to create it. ` +
      `(${err instanceof Error ? err.message : String(err)})`,
  );
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Shared tool registration: attaches ListTools + CallTool to any Server instance.
// Called once in stdio mode and once per session in HTTP mode.
// ---------------------------------------------------------------------------

const toolByName = new Map(tools.map((t) => [t.name, t]));

function registerTools(server: Server): void {
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: tools.map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: zodToJsonSchema(t.schema, { target: "openApi3" }) as any,
    })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const tool = toolByName.get(request.params.name);
    if (!tool) {
      return {
        isError: true,
        content: [{ type: "text", text: `Unknown tool: ${request.params.name}` }],
      };
    }
    try {
      const args = tool.schema.parse(request.params.arguments ?? {});
      const result = tool.handler(db, dbPath, args);
      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      };
    } catch (err) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: `Error in ${tool.name}: ${
              err instanceof Error ? err.message : String(err)
            }`,
          },
        ],
      };
    }
  });
}

// ---------------------------------------------------------------------------
// Mode selection: HTTP when CLIPPY_MCP_PORT is set to a valid port number;
// stdio otherwise (unchanged default).
// ---------------------------------------------------------------------------

const portEnv = process.env.CLIPPY_MCP_PORT;
const parsedPort = portEnv !== undefined ? parseInt(portEnv, 10) : NaN;
const useHttp =
  portEnv !== undefined &&
  portEnv.trim().length > 0 &&
  Number.isInteger(parsedPort) &&
  parsedPort > 0 &&
  parsedPort <= 65535;

if (useHttp) {
  // -------------------------------------------------------------------------
  // HTTP mode: one StreamableHTTPServerTransport per session, stored by
  // the mcp-session-id header value that the SDK assigns on initialize.
  // -------------------------------------------------------------------------

  const sessions = new Map<string, StreamableHTTPServerTransport>();

  /** Create a fresh Server + transport pair for a new MCP session. */
  function createSession(): StreamableHTTPServerTransport {
    const server = new Server(
      { name: "clippy-mcp", version: "0.1.0" },
      { capabilities: { tools: {} } },
    );
    registerTools(server);

    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
      onsessioninitialized: (sessionId) => {
        sessions.set(sessionId, transport);
      },
      onsessionclosed: (sessionId) => {
        sessions.delete(sessionId);
      },
    });

    // Clean up the session map when the transport itself closes.
    transport.onclose = () => {
      const id = transport.sessionId;
      if (id !== undefined) sessions.delete(id);
    };

    server.connect(transport).catch((err: unknown) => {
      console.error(
        `clippy-mcp: session connect error: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    });

    return transport;
  }

  /** Read the raw request body as a Buffer, then parse as JSON. */
  async function readBody(req: IncomingMessage): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const chunks: Buffer[] = [];
      req.on("data", (chunk: Buffer) => chunks.push(chunk));
      req.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        if (!raw) {
          resolve(undefined);
          return;
        }
        try {
          resolve(JSON.parse(raw));
        } catch {
          resolve(undefined);
        }
      });
      req.on("error", reject);
    });
  }

  const httpServer = http.createServer(
    async (req: IncomingMessage, res: ServerResponse) => {
      const url = new URL(req.url ?? "/", `http://127.0.0.1:${parsedPort}`);

      // Health check endpoint — no MCP handshake needed.
      if (url.pathname === "/health" && req.method === "GET") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ status: "ok" }));
        return;
      }

      // All MCP traffic goes through /mcp.
      if (url.pathname === "/mcp") {
        const sessionId = req.headers["mcp-session-id"] as string | undefined;

        if (req.method === "POST") {
          // POST: either an initialize (new session) or a subsequent request.
          const body = await readBody(req);
          let transport: StreamableHTTPServerTransport;

          if (sessionId && sessions.has(sessionId)) {
            // Existing session.
            transport = sessions.get(sessionId)!;
          } else if (sessionId) {
            // Unknown session ID — reject per spec.
            res.writeHead(404, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: "Session not found" }));
            return;
          } else {
            // No session ID on a POST: must be an initialize request.
            transport = createSession();
          }

          await transport.handleRequest(req, res, body);
          return;
        }

        if (req.method === "GET") {
          // GET opens the SSE stream for server-to-client notifications.
          if (!sessionId || !sessions.has(sessionId)) {
            res.writeHead(400, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: "Missing or invalid mcp-session-id" }));
            return;
          }
          await sessions.get(sessionId)!.handleRequest(req, res);
          return;
        }

        if (req.method === "DELETE") {
          // DELETE tears down a session.
          if (!sessionId || !sessions.has(sessionId)) {
            res.writeHead(404, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ error: "Session not found" }));
            return;
          }
          const body = await readBody(req);
          await sessions.get(sessionId)!.handleRequest(req, res, body);
          return;
        }

        res.writeHead(405, { Allow: "GET, POST, DELETE" });
        res.end();
        return;
      }

      // Unknown path.
      res.writeHead(404);
      res.end();
    },
  );

  httpServer.listen(parsedPort, "127.0.0.1", () => {
    console.error(
      `clippy-mcp HTTP listening on http://127.0.0.1:${parsedPort}/mcp (db: ${dbPath})`,
    );
  });
} else {
  // -------------------------------------------------------------------------
  // Stdio mode (default, unchanged behaviour).
  // -------------------------------------------------------------------------

  const server = new Server(
    { name: "clippy-mcp", version: "0.1.0" },
    { capabilities: { tools: {} } },
  );
  registerTools(server);

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`clippy-mcp ready (db: ${dbPath})`);
}
