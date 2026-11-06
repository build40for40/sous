import { DurableObject } from "cloudflare:workers";
import type Anthropic from "@anthropic-ai/sdk";
import type { Recipe, Session, StreamEvent, Turn, TurnRequest } from "@sous/contracts";
import { createClient, liveModel } from "./claude";
import { readDigest } from "./digest";
import { listCooks, type Cook } from "./history";
import { error, HttpError } from "./http";
import { applyPreferences, USER_MD, type Preferences, type Profile, type ProfilePatch } from "./profile";
import { assembleContext, MAX_LINKED_NOTES, MEMORY_MD, openingLine, recipeNotePath, type Note } from "./prompt";
import { fromRow, slugify, toRow, type NewRecipe, type RecipeRow } from "./recipes";
import { isRetryable, reflect, type EndRequest, type Rating, type Reflection } from "./reflection";
import { migrate } from "./schema";
import { demoRecipe, starterAbout, starterPreferences } from "./seed";
import { suggest, SUGGEST_MODEL, type Suggestion } from "./suggest";
import { appendTurnRequest, requestTurns, sse, type NewSession, type SessionRow } from "./sessions";
import { runTurn, type TurnOutcome } from "./turn";
import { deleteRecipeCascade, writeReflection } from "./vault";

interface NoteRow extends Record<string, SqlStorageValue> {
  path: string;
  frontmatter: string;
  body: string;
}

const SSE_HEADERS = { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-cache, no-transform" };
const TURN_FAILED = "Sou lost the thread there. Try that again.";
const REFLECTION_DELAY_MS = 5_000;
const REFLECTION_TIMEOUT_MS = 10 * 60_000;

export type ReflectionStatus = "not_ended" | "pending" | "done" | "failed";

/** The reflection as saved on the session, with the path of the session note it wrote. */
export type SavedReflection = Reflection & { note: string };

export interface EndedSession {
  id: string;
  ended_at: string;
  rating?: Rating;
  notes?: string;
  reflection_status: "pending";
}

export interface SessionView {
  session: Session;
  reflection: SavedReflection | null;
  reflection_status: ReflectionStatus;
  reflected_at: string | null;
}

interface FileRow extends Record<string, SqlStorageValue> {
  frontmatter: string;
  body: string;
  updated_at: string;
}

export class UserBrain extends DurableObject<Env> {
  private ready = false;
  private readonly busySessions = new Set<string>();

  private get sql(): SqlStorage {
    return this.ctx.storage.sql;
  }

  private init(): void {
    if (this.ready) return;
    this.ctx.storage.transactionSync(() => {
      const now = new Date().toISOString();
      if (migrate(this.sql, now) === 0) this.seed(now);
    });
    this.ready = true;
  }

  private seed(now: string): void {
    this.writeUserMd(starterPreferences, starterAbout, now);
    this.insertRecipe(demoRecipe, now);
  }

  getProfile(): Profile {
    this.init();
    const row = this.sql.exec<FileRow>("SELECT frontmatter, body, updated_at FROM files WHERE path = ?", USER_MD).toArray()[0];
    if (!row) return { preferences: {}, about: "", updated_at: new Date(0).toISOString() };
    return { preferences: JSON.parse(row.frontmatter), about: row.body, updated_at: row.updated_at };
  }

  updateProfile(patch: ProfilePatch): Profile | null {
    const current = this.getProfile();
    const preferences = patch.preferences ? applyPreferences(current.preferences, patch.preferences) : current.preferences;
    if (!preferences) return null;
    this.writeUserMd(preferences, patch.about ?? current.about, new Date().toISOString());
    return this.getProfile();
  }

  async wipe(): Promise<void> {
    await this.ctx.storage.deleteAll();
    this.ready = false;
  }

  listRecipes(): Recipe[] {
    this.init();
    return this.sql.exec<RecipeRow>("SELECT * FROM recipes ORDER BY created_at DESC, rowid DESC").toArray().map(fromRow);
  }

  getRecipe(id: string): Recipe | null {
    this.init();
    const row = this.sql.exec<RecipeRow>("SELECT * FROM recipes WHERE id = ?", id).toArray()[0];
    return row ? fromRow(row) : null;
  }

  createRecipe(recipe: NewRecipe): Recipe {
    this.init();
    return this.insertRecipe(recipe, new Date().toISOString());
  }

  deleteRecipe(id: string): boolean {
    this.init();
    return this.ctx.storage.transactionSync(() => {
      const row = this.sql.exec<RecipeRow>("SELECT * FROM recipes WHERE id = ?", id).toArray()[0];
      if (!row) return false;
      deleteRecipeCascade(this.sql, row);
      return true;
    });
  }

  createSession(recipeId: string): NewSession | null {
    this.init();
    const recipe = this.getRecipe(recipeId);
    if (!recipe) return null;
    const session: NewSession = {
      id: crypto.randomUUID(),
      recipe_id: recipe.id!,
      stage: "decide",
      started_at: new Date().toISOString(),
      opening_line: openingLine(recipe),
    };
    const context = this.assembleContext(recipe, session.opening_line);
    const turns: Turn[] = [{ role: "sous", at: session.started_at, text: session.opening_line }];
    this.sql.exec(
      "INSERT INTO sessions (id, recipe_id, stage, model, context, messages, turns, facts, started_at) VALUES (?, ?, ?, ?, ?, '[]', ?, '[]', ?)",
      session.id,
      session.recipe_id,
      session.stage,
      liveModel(this.env),
      context,
      JSON.stringify(turns),
      session.started_at,
    );
    return session;
  }

  /** Streams Sou's reply to one turn as server-sent events, saving the session once the reply is complete. */
  takeTurn(sessionId: string, request: TurnRequest): Response {
    this.init();
    const row = this.getSessionRow(sessionId);
    if (!row) return error(404, "session_not_found");
    if (row.ended_at) return error(409, "session_ended");
    if (this.busySessions.has(sessionId)) return error(409, "turn_in_progress");
    if (!this.env.ANTHROPIC_API_KEY) return error(503, "live_sessions_unavailable");

    let messages: Anthropic.MessageParam[];
    try {
      messages = appendTurnRequest(JSON.parse(row.messages), request);
    } catch (e) {
      if (e instanceof HttpError) return e.toResponse();
      throw e;
    }

    this.busySessions.add(sessionId);
    const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
    const writer = writable.getWriter();
    const encoder = new TextEncoder();
    const emit = (event: StreamEvent) => void writer.write(encoder.encode(sse(event))).catch(() => {});
    const at = new Date().toISOString();
    const model = row.model || liveModel(this.env);

    const work = (async () => {
      try {
        const outcome = await runTurn({
          client: createClient(this.env.ANTHROPIC_API_KEY),
          model,
          context: row.context,
          messages,
          stepCount: this.getRecipe(row.recipe_id)?.steps.length ?? 0,
          emit,
        });
        this.saveTurn(sessionId, [...requestTurns(request, at), ...outcome.turns], outcome);
        emit({ type: "done", stop_reason: outcome.stopReason });
        console.log(JSON.stringify({ event: "sous_turn", model, stop_reason: outcome.stopReason, ...outcome.timings, usage: outcome.usage }));
      } catch (e) {
        console.error(JSON.stringify({ event: "sous_turn_failed", model, error: String(e) }));
        emit({ type: "error", message: TURN_FAILED });
      } finally {
        this.busySessions.delete(sessionId);
        await writer.close().catch(() => {});
      }
    })();
    this.ctx.waitUntil(work);
    return new Response(readable, { headers: SSE_HEADERS });
  }

  /** Closes a session and schedules its reflection a few seconds later on the Durable Object's alarm. */
  async endSession(sessionId: string, request: EndRequest): Promise<EndedSession | "session_not_found" | "session_ended" | "turn_in_progress"> {
    this.init();
    const row = this.getSessionRow(sessionId);
    if (!row) return "session_not_found";
    if (row.ended_at) return "session_ended";
    if (this.busySessions.has(sessionId)) return "turn_in_progress";
    const endedAt = new Date().toISOString();
    this.sql.exec("UPDATE sessions SET ended_at = ?, rating = ?, notes = ? WHERE id = ?", endedAt, request.rating ?? null, request.notes ?? null, sessionId);
    const at = Date.now() + REFLECTION_DELAY_MS;
    const scheduled = await this.ctx.storage.getAlarm();
    if (scheduled === null || scheduled > at) await this.ctx.storage.setAlarm(at);
    return { id: sessionId, ended_at: endedAt, ...request, reflection_status: "pending" };
  }

  getSession(sessionId: string): SessionView | null {
    this.init();
    const row = this.getSessionRow(sessionId);
    if (!row) return null;
    const session: Session = {
      id: row.id,
      recipe_id: row.recipe_id,
      stage: row.stage as Session["stage"],
      started_at: row.started_at,
      ...(row.ended_at ? { ended_at: row.ended_at } : {}),
      turns: JSON.parse(row.turns),
      facts: JSON.parse(row.facts),
      ...(row.rating ? { rating: row.rating as Rating } : {}),
      ...(row.notes ? { notes: row.notes } : {}),
    };
    const status: ReflectionStatus = !row.ended_at ? "not_ended" : row.reflected_at ? "done" : row.reflection_error ? "failed" : "pending";
    return { session, reflection: row.reflection ? JSON.parse(row.reflection) : null, reflection_status: status, reflected_at: row.reflected_at };
  }

  listHistory(): Cook[] {
    this.init();
    return listCooks(this.sql);
  }

  /** Asks Sonnet what to cook from the saved recipes, given a digest of the vault. Returns an error code instead of throwing so it survives the RPC boundary. */
  async suggest(): Promise<Suggestion[] | "suggestions_unavailable" | "suggestions_failed"> {
    this.init();
    if (!this.env.ANTHROPIC_API_KEY) return "suggestions_unavailable";
    const started = Date.now();
    try {
      const digest = readDigest(this.sql, this.getProfile(), new Date());
      const { suggestions, usage } = await suggest(createClient(this.env.ANTHROPIC_API_KEY), digest);
      console.log(JSON.stringify({ event: "sous_suggest", model: SUGGEST_MODEL, candidates: digest.candidates.length, suggested: suggestions.length, total_ms: Date.now() - started, usage }));
      return suggestions;
    } catch (e) {
      console.error(JSON.stringify({ event: "sous_suggest_failed", model: SUGGEST_MODEL, error: String(e) }));
      return "suggestions_failed";
    }
  }

  /** Reflects on every ended session that hasn't been yet. Throwing makes Cloudflare retry the alarm with backoff. */
  async alarm(): Promise<void> {
    this.init();
    const pending = this.sql
      .exec<SessionRow>("SELECT * FROM sessions WHERE ended_at IS NOT NULL AND reflected_at IS NULL AND reflection_error IS NULL ORDER BY ended_at, rowid")
      .toArray();
    if (!pending.length) return;
    if (!this.env.ANTHROPIC_API_KEY) {
      console.warn(JSON.stringify({ event: "sous_reflection_skipped", reason: "no_api_key", pending: pending.length }));
      return;
    }
    const client = createClient(this.env.ANTHROPIC_API_KEY, REFLECTION_TIMEOUT_MS);
    let retry = false;
    for (const row of pending) {
      try {
        await this.reflectSession(client, row);
      } catch (e) {
        const retryable = isRetryable(e);
        console.error(JSON.stringify({ event: "sous_reflection_failed", session_id: row.id, retryable, error: String(e) }));
        if (retryable) retry = true;
        else this.sql.exec("UPDATE sessions SET reflection_error = ? WHERE id = ?", e instanceof Error ? e.message : String(e), row.id);
      }
    }
    if (retry) throw new Error("Some reflections failed and will be retried.");
  }

  private async reflectSession(client: Anthropic, row: SessionRow): Promise<void> {
    const started = Date.now();
    const recipe = this.getRecipe(row.recipe_id);
    const { preferences, about } = this.getProfile();
    const rating = (row.rating as Rating | null) ?? null;
    const { reflection, usage } = await reflect(client, { recipe, user: { preferences, about }, turns: JSON.parse(row.turns), facts: JSON.parse(row.facts), rating, notes: row.notes });
    const note = this.ctx.storage.transactionSync(() => {
      const current = this.getSessionRow(row.id);
      if (!current || current.reflected_at) return null;
      const now = new Date().toISOString();
      const path = writeReflection(this.sql, { id: row.id, started_at: row.started_at, recipe, notes: row.notes, reflection }, now);
      const saved: SavedReflection = { ...reflection, note: path };
      this.sql.exec("UPDATE sessions SET reflected_at = ?, reflection = ? WHERE id = ?", now, JSON.stringify(saved), row.id);
      return path;
    });
    console.log(JSON.stringify({ event: "sous_reflection", session_id: row.id, note, total_ms: Date.now() - started, usage }));
  }

  private getSessionRow(id: string): SessionRow | undefined {
    return this.sql.exec<SessionRow>("SELECT * FROM sessions WHERE id = ?", id).toArray()[0];
  }

  private saveTurn(sessionId: string, newTurns: Turn[], outcome: TurnOutcome): void {
    const row = this.getSessionRow(sessionId);
    if (!row) return;
    this.sql.exec(
      "UPDATE sessions SET messages = ?, turns = ?, facts = ?, stage = COALESCE(?, stage) WHERE id = ?",
      JSON.stringify(outcome.messages),
      JSON.stringify([...JSON.parse(row.turns), ...newTurns]),
      JSON.stringify([...JSON.parse(row.facts), ...outcome.facts]),
      outcome.stage,
      sessionId,
    );
  }

  private assembleContext(recipe: Recipe, opening: string): string {
    const { preferences, about } = this.getProfile();
    const notePath = recipeNotePath(recipe.slug!);
    const note = (path: string) => this.sql.exec<NoteRow>("SELECT path, frontmatter, body FROM files WHERE path = ?", path).toArray()[0] ?? null;
    const sessionNotes = this.sql
      .exec<NoteRow>(
        `SELECT path, frontmatter, body FROM files
         WHERE kind = 'session' AND path IN (SELECT src FROM links WHERE dst = ?1 UNION SELECT dst FROM links WHERE src = ?1)
         ORDER BY updated_at DESC, path DESC LIMIT 3`,
        notePath,
      )
      .toArray();
    const linkedNotes = this.sql
      .exec<NoteRow>(
        `SELECT path, frontmatter, body FROM files
         WHERE kind NOT IN ('session', 'user', 'memory', 'recipe') AND path IN (SELECT dst FROM links WHERE src = ?)
         ORDER BY path LIMIT ?`,
        notePath,
        MAX_LINKED_NOTES,
      )
      .toArray();
    return assembleContext({
      user: { preferences, about },
      memory: note(MEMORY_MD)?.body ?? null,
      recipe,
      recipeNote: note(notePath) as Note | null,
      sessionNotes,
      linkedNotes,
      openingLine: opening,
    });
  }

  private insertRecipe(recipe: NewRecipe, now: string): Recipe {
    const row = toRow(recipe, crypto.randomUUID(), this.uniqueSlug(slugify(recipe.title)), now);
    this.sql.exec(
      "INSERT INTO recipes (id, slug, source_url, title, data, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      row.id,
      row.slug,
      row.source_url,
      row.title,
      row.data,
      row.created_at,
      row.updated_at,
    );
    return fromRow(row);
  }

  private uniqueSlug(base: string): string {
    const taken = (slug: string) => this.sql.exec("SELECT 1 FROM recipes WHERE slug = ?", slug).toArray().length > 0;
    let slug = base;
    for (let n = 2; taken(slug); n++) slug = `${base}-${n}`;
    return slug;
  }

  private writeUserMd(preferences: Preferences, about: string, now: string): void {
    this.sql.exec(
      `INSERT INTO files (path, kind, frontmatter, body, updated_at) VALUES (?, 'user', ?, ?, ?)
       ON CONFLICT (path) DO UPDATE SET frontmatter = excluded.frontmatter, body = excluded.body, updated_at = excluded.updated_at`,
      USER_MD,
      JSON.stringify(preferences),
      about,
      now,
    );
  }
}
