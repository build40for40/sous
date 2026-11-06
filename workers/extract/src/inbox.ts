import { DurableObject } from "cloudflare:workers";
import type { Recipe } from "@sous/contracts";
import type { NewRecipe } from "./extract";
import type { PostResult } from "./post";

/**
 * One Durable Object per user (named by their WorkOS id): everything they've shared
 * and what happened to each. Finished recipes go into the user's brain, so they show
 * up in GET /recipes alongside everything else.
 */

export type ShareStatus = "reading" | "saved" | "needs_screenshot" | "no_recipe" | "skipped";

export interface Share {
  id: string;
  kind: "link" | "screenshot";
  url: string | null;
  status: ShareStatus;
  reason: string | null;
  title: string | null;
  creator: string | null;
  recipe_id: string | null;
  source_used: string | null;
  completeness: string | null;
  missing: string[];
  created_at: string;
  updated_at: string;
}

interface ShareRow extends Record<string, SqlStorageValue> {
  id: string;
  kind: string;
  post_key: string;
  url: string | null;
  status: string;
  reason: string | null;
  title: string | null;
  creator: string | null;
  recipe_id: string | null;
  source_used: string | null;
  completeness: string | null;
  missing: string;
  created_at: string;
  updated_at: string;
}

type Brain = { createRecipe(recipe: NewRecipe): Promise<Recipe> };

const STATUS: Record<PostResult["status"], ShareStatus> = { recipe: "saved", needs_screenshot: "needs_screenshot", no_recipe: "no_recipe", meal_prep: "skipped" };

export class ShareInbox extends DurableObject<Env> {
  private get sql(): SqlStorage {
    return this.ctx.storage.sql;
  }

  private init(userId?: string): void {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS shares (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, post_key TEXT NOT NULL, url TEXT, status TEXT NOT NULL,
      reason TEXT, title TEXT, creator TEXT, recipe_id TEXT, source_used TEXT, completeness TEXT,
      missing TEXT NOT NULL DEFAULT '[]', created_at TEXT NOT NULL, updated_at TEXT NOT NULL)`);
    this.sql.exec("CREATE INDEX IF NOT EXISTS shares_post_key ON shares (post_key)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    // One row per read that might cost a Claude call: a new share, a re-share that retries, a screenshot.
    this.sql.exec("CREATE TABLE IF NOT EXISTS reads (at TEXT NOT NULL)");
    if (userId) this.sql.exec("INSERT OR IGNORE INTO meta VALUES ('user_id', ?)", userId);
  }

  /** Counts a read toward the daily limit, or says the limit is reached. */
  private allow(dailyLimit: number): boolean {
    const now = Date.now();
    this.sql.exec("DELETE FROM reads WHERE at < ?", new Date(now - 48 * 3600_000).toISOString());
    const today = this.sql.exec<{ n: number }>("SELECT COUNT(*) AS n FROM reads WHERE at > ?", new Date(now - 24 * 3600_000).toISOString()).one().n;
    if (today >= dailyLimit) return false;
    this.sql.exec("INSERT INTO reads VALUES (?)", new Date(now).toISOString());
    return true;
  }

  /**
   * Saves a share, or returns the existing one if this person already shared the same post.
   * Sharing again a post that came back needs_screenshot reads it again, since the reason
   * may have been temporary (Instagram having a bad day, a post that was private).
   */
  addShare(userId: string, kind: Share["kind"], postKey: string, url: string | null, dailyLimit: number): { share: Share; duplicate: boolean } | "daily_limit" {
    this.init(userId);
    const existing = this.sql.exec<ShareRow>("SELECT * FROM shares WHERE post_key = ? ORDER BY created_at DESC LIMIT 1", postKey).toArray()[0];
    if (existing && existing.status !== "needs_screenshot") return { share: toShare(existing), duplicate: true };
    if (!this.allow(dailyLimit)) return "daily_limit";
    const now = new Date().toISOString();
    if (existing) {
      this.sql.exec("UPDATE shares SET status = 'reading', reason = NULL, updated_at = ? WHERE id = ?", now, existing.id);
      return { share: this.get(existing.id)!, duplicate: false };
    }
    const id = crypto.randomUUID();
    this.sql.exec("INSERT INTO shares (id, kind, post_key, url, status, created_at, updated_at) VALUES (?, ?, ?, ?, 'reading', ?, ?)", id, kind, postKey, url, now, now);
    return { share: this.get(id)!, duplicate: false };
  }

  /**
   * A screenshot for a share that came back needs_screenshot: the share starts reading again
   * from the image. Only for that status (a saved share would end up with a second recipe),
   * and it counts toward the daily limit like any other read.
   */
  attachScreenshot(shareId: string, postKey: string, dailyLimit: number): Share | "not_found" | "share_in_progress" | "screenshot_not_needed" | "daily_limit" {
    this.init();
    const row = this.sql.exec<ShareRow>("SELECT * FROM shares WHERE id = ?", shareId).toArray()[0];
    if (!row) return "not_found";
    if (row.status === "reading") return "share_in_progress";
    if (row.status !== "needs_screenshot") return "screenshot_not_needed";
    if (!this.allow(dailyLimit)) return "daily_limit";
    this.sql.exec("UPDATE shares SET kind = 'screenshot', post_key = ?, status = 'reading', reason = NULL, updated_at = ? WHERE id = ?", postKey, new Date().toISOString(), shareId);
    return this.get(shareId)!;
  }

  list(): Share[] {
    this.init();
    return this.sql.exec<ShareRow>("SELECT * FROM shares ORDER BY created_at DESC, rowid DESC LIMIT 500").toArray().map(toShare);
  }

  get(id: string): Share | null {
    this.init();
    const row = this.sql.exec<ShareRow>("SELECT * FROM shares WHERE id = ?", id).toArray()[0];
    return row ? toShare(row) : null;
  }

  /** Forgets the share. A recipe already saved stays in the brain; delete it there. */
  remove(id: string): boolean {
    this.init();
    return this.sql.exec("DELETE FROM shares WHERE id = ?", id).rowsWritten > 0;
  }

  /** Deletes everything Sous holds about this person's shares (for account deletion). */
  async wipe(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }

  /** Called by the post's Durable Object (or the request itself, for a cached post) when its result is ready. */
  async complete(shareId: string, result: PostResult): Promise<Share | null> {
    this.init();
    const row = this.sql.exec<ShareRow>("SELECT * FROM shares WHERE id = ?", shareId).toArray()[0];
    if (!row || row.status !== "reading") return row ? toShare(row) : null; // deleted, or already done
    const userId = this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'user_id'").toArray()[0]?.value;

    let recipeId: string | null = null;
    if (result.status === "recipe" && result.recipe && userId) {
      const brain = this.env.USER_BRAIN.get(this.env.USER_BRAIN.idFromName(userId)) as unknown as Brain;
      recipeId = (await brain.createRecipe(result.recipe)).id ?? null;
    }
    this.sql.exec(
      `UPDATE shares SET status = ?, reason = ?, title = ?, creator = ?, recipe_id = ?, source_used = ?,
       completeness = ?, missing = ?, updated_at = ? WHERE id = ?`,
      STATUS[result.status],
      result.reason,
      result.recipe?.title ?? null,
      result.creator,
      recipeId,
      result.source_used,
      result.completeness,
      JSON.stringify(result.missing),
      new Date().toISOString(),
      shareId,
    );
    return this.get(shareId);
  }
}

function toShare(row: ShareRow): Share {
  return {
    id: row.id,
    kind: row.kind as Share["kind"],
    url: row.url,
    status: row.status as ShareStatus,
    reason: row.reason,
    title: row.title,
    creator: row.creator,
    recipe_id: row.recipe_id,
    source_used: row.source_used,
    completeness: row.completeness,
    missing: JSON.parse(row.missing) as string[],
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}
