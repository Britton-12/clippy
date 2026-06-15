import type { DatabaseSync } from "node:sqlite";
import path from "node:path";
import { z } from "zod";
import {
  buildPrefixPattern,
  grdbNow,
  grdbToIso,
  resolveMediaDir,
} from "./db.js";

// ---------------------------------------------------------------------------
// Row shapes (subset of columns we read)
// ---------------------------------------------------------------------------

interface ClipRow {
  id: number;
  contentText: string;
  typeIdentifier: string;
  sourceAppName: string | null;
  sourceAppBundleID: string | null;
  userTitle: string | null;
  createdAt: string;
  contentKind: string;
  mediaFilename: string | null;
  thumbFilename: string | null;
  pixelWidth: number | null;
  pixelHeight: number | null;
  byteSize: number | null;
}

interface CategoryRow {
  id: number;
  name: string;
  colorHex: string;
  iconKind: string;
  iconValue: string;
  sortOrder: number;
  isStarter: number;
  createdAt: string;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function preview(text: string): string {
  return text.trim().slice(0, 300);
}

function titleFor(row: Pick<ClipRow, "userTitle" | "sourceAppName">): string {
  return row.userTitle ?? row.sourceAppName ?? "Unknown app";
}

/** category id+name list for a clip, used in search/list results. */
function categoriesForClip(db: DatabaseSync, clipID: number) {
  const rows = db
    .prepare(
      `SELECT c.id AS id, c.name AS name
         FROM clip_category cc
         JOIN category c ON c.id = cc.categoryID
        WHERE cc.clipID = ?
        ORDER BY c.sortOrder, c.createdAt`,
    )
    .all(clipID) as { id: number; name: string }[];
  return rows;
}

// ---------------------------------------------------------------------------
// Tool definitions. Each: { name, description, inputSchema (zod), handler }.
// Handlers return a plain JSON-serializable object.
// ---------------------------------------------------------------------------

export interface ToolDef {
  name: string;
  description: string;
  schema: z.ZodTypeAny;
  handler: (db: DatabaseSync, dbPath: string, args: any) => unknown;
}

const limitSchema = z.number().int().positive().max(500).optional();

export const tools: ToolDef[] = [
  {
    name: "clippy_search",
    description:
      "Full-text search clips via the FTS5 index (same ranking as the app). " +
      "Returns id, title, preview, kind, createdAt, and categories. " +
      "Query terms are prefix-matched (e.g. 'foo' matches 'foobar').",
    schema: z.object({
      query: z.string().min(1).describe("Search text. Prefix-matched per term."),
      limit: limitSchema.describe("Max results (default 25)."),
    }),
    handler: (db, _dbPath, args) => {
      const { query, limit } = args as { query: string; limit?: number };
      const pattern = buildPrefixPattern(query);
      if (!pattern) return { results: [] };
      const rows = db
        .prepare(
          `SELECT clips.* FROM clips
             JOIN clips_fts ON clips_fts.rowid = clips.id
            WHERE clips_fts MATCH ?
            ORDER BY rank
            LIMIT ?`,
        )
        .all(pattern, limit ?? 25) as unknown as ClipRow[];
      return {
        results: rows.map((r) => ({
          id: r.id,
          title: titleFor(r),
          preview: preview(r.contentText),
          kind: r.contentKind,
          createdAt: grdbToIso(r.createdAt),
          categories: categoriesForClip(db, r.id),
        })),
      };
    },
  },
  {
    name: "clippy_list_recent",
    description:
      "List the most recent clips, newest first. Returns id, title, preview, " +
      "kind, createdAt, and categories.",
    schema: z.object({
      limit: limitSchema.describe("Max results (default 25)."),
    }),
    handler: (db, _dbPath, args) => {
      const { limit } = args as { limit?: number };
      const rows = db
        .prepare(
          `SELECT * FROM clips ORDER BY createdAt DESC, id DESC LIMIT ?`,
        )
        .all(limit ?? 25) as unknown as ClipRow[];
      return {
        results: rows.map((r) => ({
          id: r.id,
          title: titleFor(r),
          preview: preview(r.contentText),
          kind: r.contentKind,
          createdAt: grdbToIso(r.createdAt),
          categories: categoriesForClip(db, r.id),
        })),
      };
    },
  },
  {
    name: "clippy_get",
    description:
      "Fetch one clip in full by id: contentText, title, kind, timestamps, " +
      "categories, and (for image clips) the absolute media + thumbnail file paths.",
    schema: z.object({
      id: z.number().int().positive().describe("Clip id."),
    }),
    handler: (db, dbPath, args) => {
      const { id } = args as { id: number };
      const row = db.prepare(`SELECT * FROM clips WHERE id = ?`).get(id) as
        | ClipRow
        | undefined;
      if (!row) return { error: "not_found", id };
      const mediaDir = resolveMediaDir(dbPath);
      return {
        id: row.id,
        title: titleFor(row),
        contentText: row.contentText,
        typeIdentifier: row.typeIdentifier,
        kind: row.contentKind,
        sourceAppName: row.sourceAppName,
        sourceAppBundleID: row.sourceAppBundleID,
        userTitle: row.userTitle,
        createdAt: grdbToIso(row.createdAt),
        categories: categoriesForClip(db, row.id),
        media:
          row.contentKind === "image" && row.mediaFilename
            ? {
                mediaPath: path.join(mediaDir, row.mediaFilename),
                thumbPath: row.thumbFilename
                  ? path.join(mediaDir, row.thumbFilename)
                  : null,
                pixelWidth: row.pixelWidth,
                pixelHeight: row.pixelHeight,
                byteSize: row.byteSize,
              }
            : null,
      };
    },
  },
  {
    name: "clippy_add",
    description:
      "Insert a new plain-text clip. The FTS index is kept current automatically " +
      "by the app's triggers. Returns the new clip id.",
    schema: z.object({
      text: z.string().min(1).describe("The clip's text content."),
      title: z
        .string()
        .optional()
        .describe("Optional custom display title (userTitle)."),
    }),
    handler: (db, _dbPath, args) => {
      const { text, title } = args as { text: string; title?: string };
      const now = grdbNow();
      const info = db
        .prepare(
          `INSERT INTO clips
             (contentText, typeIdentifier, sourceAppName, createdAt, contentKind, userTitle)
           VALUES (?, 'public.utf8-plain-text', 'clippy-mcp', ?, 'text', ?)`,
        )
        .run(text, now, title ?? null);
      return { id: Number(info.lastInsertRowid), createdAt: grdbToIso(now) };
    },
  },
  {
    name: "clippy_delete",
    description:
      "Delete a clip by id. Cascades to remove its category memberships and " +
      "FTS entry. Does not delete media files on disk.",
    schema: z.object({
      id: z.number().int().positive().describe("Clip id to delete."),
    }),
    handler: (db, _dbPath, args) => {
      const { id } = args as { id: number };
      const info = db.prepare(`DELETE FROM clips WHERE id = ?`).run(id);
      return { deleted: info.changes > 0, id };
    },
  },
  {
    name: "clippy_list_categories",
    description:
      "List all categories (pinboards) with id, name, colorHex, icon, and " +
      "whether each is the starter category.",
    schema: z.object({}),
    handler: (db) => {
      const rows = db
        .prepare(
          `SELECT * FROM category ORDER BY sortOrder, createdAt`,
        )
        .all() as unknown as CategoryRow[];
      return {
        categories: rows.map((c) => ({
          id: c.id,
          name: c.name,
          colorHex: c.colorHex,
          iconKind: c.iconKind,
          iconValue: c.iconValue,
          sortOrder: c.sortOrder,
          isStarter: c.isStarter === 1,
        })),
      };
    },
  },
  {
    name: "clippy_set_category",
    description:
      "Add or remove a clip's membership in a category. member=true inserts " +
      "the clip_category row (idempotent); member=false removes it.",
    schema: z.object({
      clipID: z.number().int().positive().describe("Clip id."),
      categoryID: z.number().int().positive().describe("Category id."),
      member: z
        .boolean()
        .describe("true to add to the category, false to remove."),
    }),
    handler: (db, _dbPath, args) => {
      const { clipID, categoryID, member } = args as {
        clipID: number;
        categoryID: number;
        member: boolean;
      };
      if (member) {
        db.prepare(
          `INSERT OR IGNORE INTO clip_category (clipID, categoryID, addedAt) VALUES (?, ?, ?)`,
        ).run(clipID, categoryID, grdbNow());
      } else {
        db.prepare(
          `DELETE FROM clip_category WHERE clipID = ? AND categoryID = ?`,
        ).run(clipID, categoryID);
      }
      return { clipID, categoryID, member };
    },
  },
  {
    name: "clippy_create_category",
    description:
      "Create a new category (pinboard). colorHex defaults to #FF9500. " +
      "sortOrder is appended after existing categories; isStarter is always 0. " +
      "Returns the new category id.",
    schema: z.object({
      name: z.string().min(1).describe("Category name."),
      colorHex: z
        .string()
        .regex(/^#?[0-9A-Fa-f]{6}$/)
        .optional()
        .describe("Hex color like #FF9500. Defaults to #FF9500."),
      iconKind: z
        .enum(["symbol", "emoji", "appLogo"])
        .optional()
        .describe("Icon kind. Defaults to symbol."),
      iconValue: z
        .string()
        .optional()
        .describe("SF Symbol name, emoji, or bundle id. Defaults to tag.fill."),
    }),
    handler: (db, _dbPath, args) => {
      const { name, colorHex, iconKind, iconValue } = args as {
        name: string;
        colorHex?: string;
        iconKind?: string;
        iconValue?: string;
      };
      const color = colorHex
        ? colorHex.startsWith("#")
          ? colorHex
          : `#${colorHex}`
        : "#FF9500";
      const kind = iconKind ?? "symbol";
      const value = iconValue ?? "tag.fill";
      const maxOrder = (
        db.prepare(`SELECT IFNULL(MAX(sortOrder), -1) AS m FROM category`).get() as {
          m: number;
        }
      ).m;
      const info = db
        .prepare(
          `INSERT INTO category
             (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
           VALUES (?, ?, ?, ?, ?, 0, ?)`,
        )
        .run(name, color, kind, value, maxOrder + 1, grdbNow());
      return {
        id: Number(info.lastInsertRowid),
        name,
        colorHex: color,
        sortOrder: maxOrder + 1,
      };
    },
  },
];
