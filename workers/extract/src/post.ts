import { DurableObject } from "cloudflare:workers";
import { createClient, extract, extractModel, isRetryable, type Extraction, type ExtractionInput, type ImageType } from "./extract";
import { findRecipeLink, readInstagramPost, readRecipePage, SourceError } from "./sources";

/**
 * One Durable Object per post (or per screenshot), keyed `ig:<shortcode>`, `web:<hash>`
 * or `img:<hash>`. It reads the sources and calls Claude once, however many people share
 * the same post, then hands the result to everyone waiting on it.
 */

const MAX_ATTEMPTS = 5;
const RETRY_DELAYS_MS = [10_000, 60_000, 5 * 60_000, 30 * 60_000];

export type PostSource =
  | { kind: "instagram"; key: string; url: string; shortcode: string }
  | { kind: "web"; key: string; url: string }
  | { kind: "screenshot"; key: string; url: string | null; media_type: ImageType; image: ArrayBuffer };

export type PostResult = Extraction & { creator: string | null; extracted_at: string; model: string };

export interface Waiter {
  user_id: string;
  share_id: string;
}

interface StateRow extends Record<string, SqlStorageValue> {
  kind: string;
  url: string | null;
  shortcode: string | null;
  media_type: string | null;
  image: ArrayBuffer | null;
  result: string | null;
  attempts: number;
  last_error: string | null;
}

export class PostExtraction extends DurableObject<Env> {
  private get sql(): SqlStorage {
    return this.ctx.storage.sql;
  }

  private init(): void {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS state (
      id INTEGER PRIMARY KEY CHECK (id = 1), kind TEXT NOT NULL, url TEXT, shortcode TEXT,
      media_type TEXT, image BLOB, result TEXT, attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT)`);
    this.sql.exec("CREATE TABLE IF NOT EXISTS waiters (user_id TEXT NOT NULL, share_id TEXT NOT NULL, PRIMARY KEY (user_id, share_id))");
  }

  /**
   * Someone shared this post. If it's already been read, the result comes straight back
   * and nothing is fetched again; otherwise they wait and the alarm does the work.
   */
  async request(source: PostSource, waiter: Waiter): Promise<PostResult | null> {
    this.init();
    let state = this.sql.exec<StateRow>("SELECT * FROM state").toArray()[0];
    if (!state) {
      this.sql.exec(
        "INSERT INTO state (id, kind, url, shortcode, media_type, image) VALUES (1, ?, ?, ?, ?, ?)",
        source.kind,
        source.url,
        source.kind === "instagram" ? source.shortcode : null,
        source.kind === "screenshot" ? source.media_type : null,
        source.kind === "screenshot" ? source.image : null,
      );
      state = this.sql.exec<StateRow>("SELECT * FROM state").toArray()[0];
    }
    if (state.result) return JSON.parse(state.result) as PostResult;
    this.sql.exec("INSERT OR IGNORE INTO waiters VALUES (?, ?)", waiter.user_id, waiter.share_id);
    if ((await this.ctx.storage.getAlarm()) === null) await this.ctx.storage.setAlarm(Date.now());
    return null;
  }

  /** Reads the sources, calls Claude, then delivers to every waiter. */
  async alarm(): Promise<void> {
    this.init();
    const state = this.sql.exec<StateRow>("SELECT * FROM state").toArray()[0];
    if (!state) return;
    let result: PostResult | null = state.result ? (JSON.parse(state.result) as PostResult) : null;

    if (!result) {
      if (!this.env.ANTHROPIC_API_KEY) return; // nothing works without Claude; a later share re-arms the alarm
      const attempt = state.attempts + 1;
      this.sql.exec("UPDATE state SET attempts = ?", attempt);
      try {
        result = await this.run(state);
      } catch (e) {
        const message = (e as Error).message.slice(0, 500);
        this.sql.exec("UPDATE state SET last_error = ?", message);
        const retry = (e instanceof SourceError ? e.retry : isRetryable(e)) && attempt < MAX_ATTEMPTS;
        console.log(JSON.stringify({ event: "sous_extract_error", key: this.ctx.id.name, attempt, retry, message }));
        if (retry) {
          await this.ctx.storage.setAlarm(Date.now() + RETRY_DELAYS_MS[attempt - 1]);
          return;
        }
        result = failed(state, message);
      }
      this.sql.exec("UPDATE state SET result = ?, image = NULL", JSON.stringify(result));
    }
    await this.deliver(result);
  }

  private async run(state: StateRow): Promise<PostResult> {
    const input: ExtractionInput = { source_url: state.url, creator: null, caption: null, recipe_page: null, screenshot: null, notes: [] };
    let creator: string | null = null;

    if (state.kind === "instagram") {
      try {
        const post = await readInstagramPost(state.shortcode!);
        creator = post.creator;
        input.creator = post.creator;
        input.caption = post.caption;
      } catch (e) {
        if (e instanceof SourceError && !e.retry) {
          // Private, deleted or unreadable: no point asking Claude about nothing.
          return { status: "needs_screenshot", reason: "Sous couldn't open this post. It may be private or deleted.", source_used: "none", completeness: "none", missing: [], recipe: null, creator: null, extracted_at: now(), model: "none" };
        }
        throw e;
      }
      const link = input.caption ? findRecipeLink(input.caption) : null;
      if (link) input.recipe_page = await this.recipePage(link, input.notes);
      input.notes.push("The video, its audio and the comments are not available to Sous.");
    } else if (state.kind === "web") {
      input.recipe_page = await this.recipePage(state.url!, input.notes, true);
      if (!input.recipe_page.text) {
        return { status: "needs_screenshot", reason: "Sous couldn't find a recipe on that page.", source_used: "none", completeness: "none", missing: [], recipe: null, creator: null, extracted_at: now(), model: "none" };
      }
    } else {
      input.screenshot = { media_type: state.media_type as ImageType, data: base64(state.image!) };
    }

    const model = extractModel(this.env);
    const started = Date.now();
    const { extraction, usage } = await extract(createClient(this.env.ANTHROPIC_API_KEY), model, input);
    console.log(JSON.stringify({ event: "sous_extract", key: this.ctx.id.name, kind: state.kind, model, status: extraction.status, source_used: extraction.source_used, ms: Date.now() - started, usage }));
    return { ...extraction, creator, extracted_at: now(), model };
  }

  /** A recipe page is a bonus: if it can't be read, carry on with the caption. A shared web page is the only source, so its errors count. */
  private async recipePage(url: string, notes: string[], required = false): Promise<{ url: string; text: string | null }> {
    try {
      return { url, text: await readRecipePage(url) };
    } catch (e) {
      if (required && e instanceof SourceError && e.retry) throw e;
      notes.push(`The linked page ${url} couldn't be opened (${(e as Error).message}).`);
      return { url, text: null };
    }
  }

  private async deliver(result: PostResult): Promise<void> {
    for (const w of this.sql.exec<{ user_id: string; share_id: string }>("SELECT user_id, share_id FROM waiters").toArray()) {
      const inbox = this.env.SHARE_INBOX.get(this.env.SHARE_INBOX.idFromName(w.user_id));
      await inbox.complete(w.share_id, result);
      this.sql.exec("DELETE FROM waiters WHERE user_id = ? AND share_id = ?", w.user_id, w.share_id);
    }
  }
}

function failed(state: StateRow, message: string): PostResult {
  const reason = state.kind === "instagram" ? "Sous couldn't read this post right now. Try sharing a screenshot of the recipe." : "Sous couldn't read this right now. Try again later.";
  return { status: "needs_screenshot", reason, source_used: "none", completeness: "none", missing: [], recipe: null, creator: null, extracted_at: now(), model: `failed: ${message.slice(0, 100)}` };
}

function now(): string {
  return new Date().toISOString();
}

function base64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}
