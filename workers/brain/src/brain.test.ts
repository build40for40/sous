import { env } from "cloudflare:workers";
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { UserBrain } from "./brain";
import { SCHEMA_VERSION } from "./schema";
import { demoRecipe } from "./seed";
import { fakeReflection, mockClaude } from "./testing";

afterEach(() => {
  vi.restoreAllMocks();
});

const brainFor = (name: string) => env.USER_BRAIN.get(env.USER_BRAIN.idFromName(name));

const tables = (state: DurableObjectState) =>
  state.storage.sql
    .exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\' ORDER BY name")
    .toArray()
    .map((r) => r.name);

describe("UserBrain", () => {
  it("creates the schema and seeds USER.md and the demo recipe on first use", async () => {
    await runInDurableObject(brainFor("user_schema"), (brain: UserBrain, state) => {
      expect(tables(state)).toEqual([]);
      brain.listRecipes();
      expect(tables(state)).toEqual(["files", "links", "recipes", "schema_migrations", "sessions"]);
      expect(state.storage.sql.exec("SELECT MAX(version) AS v FROM schema_migrations").one().v).toBe(SCHEMA_VERSION);
      expect(state.storage.sql.exec("SELECT path, kind FROM files").toArray()).toEqual([{ path: "USER.md", kind: "user" }]);
      expect(brain.listRecipes().map((r) => r.title)).toEqual([demoRecipe.title]);
    });
  });

  it("seeds only once", async () => {
    const stub = brainFor("user_once");
    await runInDurableObject(stub, (brain: UserBrain) => {
      brain.deleteRecipe(brain.listRecipes()[0].id!);
    });
    await runInDurableObject(stub, (brain: UserBrain) => {
      expect(brain.listRecipes()).toEqual([]);
    });
  });

  it("rejects vault files of an unknown kind", async () => {
    await runInDurableObject(brainFor("user_kinds"), (brain: UserBrain, state) => {
      brain.getProfile();
      expect(() =>
        state.storage.sql.exec("INSERT INTO files (path, kind, updated_at) VALUES ('x.md', 'shopping', '2026-11-06T00:00:00Z')"),
      ).toThrow();
    });
  });

  it("keeps preferences under the size limit", async () => {
    await runInDurableObject(brainFor("user_big"), (brain: UserBrain) => {
      expect(brain.updateProfile({ preferences: { notes: "x".repeat(20_000) } })).toBeNull();
      expect(brain.getProfile().preferences).not.toHaveProperty("notes");
    });
  });

  it("wipe deletes everything, and the next use starts fresh", async () => {
    const stub = brainFor("user_wipe");
    await runInDurableObject(stub, async (brain: UserBrain, state) => {
      brain.createRecipe({ title: "Fake Wipe Me", ingredients: [{ name: "salt" }], steps: [{ text: "Season." }] });
      await brain.wipe();
      expect(tables(state)).toEqual([]);
      expect(brain.listRecipes().map((r) => r.title)).toEqual([demoRecipe.title]);
    });
  });

  it("adds the live session columns", async () => {
    await runInDurableObject(brainFor("user_columns"), (brain: UserBrain, state) => {
      brain.listRecipes();
      const columns = state.storage.sql.exec<{ name: string }>("PRAGMA table_info(sessions)").toArray().map((c) => c.name);
      expect(columns).toEqual(expect.arrayContaining(["model", "context", "turns", "facts", "rating", "notes", "reflection_error"]));
    });
  });

  it("starts a session with its context assembled once from the vault", async () => {
    await runInDurableObject(brainFor("user_vault"), (brain: UserBrain, state) => {
      const recipe = brain.listRecipes()[0];
      const note = `recipes/${recipe.slug}.md`;
      const now = "2026-11-06T12:00:00Z";
      const file = (path: string, kind: string, body: string, updated = now) =>
        state.storage.sql.exec("INSERT INTO files (path, kind, body, updated_at) VALUES (?, ?, ?, ?)", path, kind, body, updated);
      const link = (src: string, dst: string) => state.storage.sql.exec("INSERT INTO links (src, dst, kind) VALUES (?, ?, 'mentions')", src, dst);
      file("MEMORY.md", "memory", "Always preheat the pan.");
      file(note, "recipe", "Best with mature cheddar.");
      for (const [n, day] of [[1, "01"], [2, "02"], [3, "03"], [4, "04"]] as const) {
        file(`sessions/s${n}.md`, "session", `Cook number ${n}.`, `2026-11-${day}T18:00:00Z`);
        link(`sessions/s${n}.md`, note);
      }
      file("sessions/other.md", "session", "A different recipe.");
      file("ingredients/cheddar.md", "ingredient", "Grate it fine.");
      file("cuisines/british.md", "cuisine", "Toasties count.");
      file("ingredients/unlinked.md", "ingredient", "Never mentioned.");
      link(note, "ingredients/cheddar.md");
      link(note, "cuisines/british.md");

      const session = brain.createSession(recipe.id!)!;
      expect(session.opening_line).toContain(recipe.title);
      const row = state.storage.sql.exec("SELECT * FROM sessions WHERE id = ?", session.id).one();
      expect(row).toMatchObject({ recipe_id: recipe.id, stage: "decide", model: "claude-sonnet-5-5", messages: "[]", facts: "[]" });
      const context = row.context as string;
      for (const text of ["Always preheat the pan.", "Best with mature cheddar.", "Cook number 4.", "Cook number 3.", "Cook number 2.", "Grate it fine.", "Toasties count.", session.opening_line]) {
        expect(context).toContain(text);
      }
      for (const text of ["Cook number 1.", "A different recipe.", "Never mentioned."]) {
        expect(context).not.toContain(text);
      }
      expect(context.indexOf("Cook number 4.")).toBeLessThan(context.indexOf("Cook number 2."));
    });
  });

  it("won't start a session for a recipe it doesn't have", async () => {
    await runInDurableObject(brainFor("user_norecipe"), (brain: UserBrain) => {
      expect(brain.createSession("nope")).toBeNull();
    });
  });

  describe("reflection alarm", () => {
    const reflectionReply = { content: [{ type: "text" as const, text: JSON.stringify(fakeReflection) }] };

    async function endedSession(brain: UserBrain, state: DurableObjectState) {
      const id = brain.createSession(brain.listRecipes()[0].id!)!.id;
      expect(await brain.endSession(id, { rating: 4 })).toMatchObject({ id, rating: 4, reflection_status: "pending" });
      expect(await state.storage.getAlarm()).toEqual(expect.any(Number));
      return id;
    }

    it("retries later when Claude is down, then reflects once", async () => {
      const stub = brainFor("user_alarmRetry");
      await runInDurableObject(stub, async (brain: UserBrain, state) => {
        const id = await endedSession(brain, state);
        const claude = mockClaude({ status: 529, message: "overloaded" }, { status: 529, message: "overloaded" }, reflectionReply);
        await expect(brain.alarm()).rejects.toThrow("will be retried");
        expect(brain.getSession(id)).toMatchObject({ reflection_status: "pending", reflection: null });

        await brain.alarm();
        expect(claude.requests).toHaveLength(3);
        expect(brain.getSession(id)).toMatchObject({ reflection_status: "done", reflection: { rating: 4 } });
        const notes = state.storage.sql.exec("SELECT COUNT(*) AS n FROM files WHERE kind = 'session'").one().n;

        await brain.alarm();
        expect(claude.requests).toHaveLength(3);
        expect(state.storage.sql.exec("SELECT COUNT(*) AS n FROM files WHERE kind = 'session'").one().n).toBe(notes);
      });
      await runDurableObjectAlarm(stub);
    });

    it("gives up on a reflection that can never work, and carries on with the rest", async () => {
      const stub = brainFor("user_alarmRefusal");
      await runInDurableObject(stub, async (brain: UserBrain, state) => {
        const refused = await endedSession(brain, state);
        const fine = await endedSession(brain, state);
        const claude = mockClaude({ content: [{ type: "text", text: "No." }], stop_reason: "refusal" }, reflectionReply);
        await brain.alarm();
        expect(brain.getSession(refused)).toMatchObject({ reflection_status: "failed", reflection: null });
        expect(brain.getSession(fine)).toMatchObject({ reflection_status: "done" });

        await brain.alarm();
        expect(claude.requests).toHaveLength(2);
      });
      await runDurableObjectAlarm(stub);
    });
  });
});
