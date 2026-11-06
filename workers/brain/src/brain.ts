import { DurableObject } from "cloudflare:workers";
import type Anthropic from "@anthropic-ai/sdk";
import type { Recipe, StreamEvent, Turn, TurnRequest } from "@sous/contracts";
import { createClient, liveModel } from "./claude";
import { error, HttpError } from "./http";
import { applyPreferences, USER_MD, type Preferences, type Profile, type ProfilePatch } from "./profile";
import { assembleContext, MAX_LINKED_NOTES, MEMORY_MD, openingLine, recipeNotePath, type Note } from "./prompt";
import { fromRow, slugify, toRow, type NewRecipe, type RecipeRow } from "./recipes";
import { migrate } from "./schema";
import { demoRecipe, starterAbout, starterPreferences } from "./seed";
import { appendTurnRequest, requestTurns, sse, type NewSession, type SessionRow } from "./sessions";
import { runTurn, type TurnOutcome } from "./turn";

interface NoteRow extends Record<string, SqlStorageValue> {
  path: string;
  frontmatter: string;
  body: string;
}

const SSE_HEADERS = { "Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-cache, no-transform" };
const TURN_FAILED = "Sou lost the thread there. Try that again.";

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
    return this.sql.exec("DELETE FROM recipes WHERE id = ?", id).rowsWritten > 0;
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
