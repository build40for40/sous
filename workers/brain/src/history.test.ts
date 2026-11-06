import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { UserBrain } from "./brain";
import { MAX_HISTORY, listCooks } from "./history";

async function inBrain<T>(name: string, run: (sql: SqlStorage, brain: UserBrain) => T): Promise<T> {
  return runInDurableObject(env.USER_BRAIN.get(env.USER_BRAIN.idFromName(name)), (brain: UserBrain, state) => {
    brain.getProfile();
    return run(state.storage.sql, brain);
  });
}

interface FakeSession {
  id: string;
  recipe_id?: string | null;
  started_at: string;
  ended_at?: string | null;
  rating?: number | null;
  reflection?: object | null;
  reflected_at?: string | null;
  reflection_error?: string | null;
}

function addSession(sql: SqlStorage, s: FakeSession): void {
  sql.exec(
    "INSERT INTO sessions (id, recipe_id, started_at, ended_at, rating, reflection, reflected_at, reflection_error) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    s.id,
    s.recipe_id ?? null,
    s.started_at,
    s.ended_at === undefined ? "2026-11-06T19:00:00Z" : s.ended_at,
    s.rating ?? null,
    s.reflection ? JSON.stringify(s.reflection) : null,
    s.reflected_at ?? null,
    s.reflection_error ?? null,
  );
}

describe("listCooks", () => {
  it("lists finished cooks newest first, with the recipe title and the London date", async () => {
    await inBrain("history_order", (sql, brain) => {
      const demo = brain.listRecipes()[0];
      addSession(sql, { id: "old", recipe_id: demo.id, started_at: "2026-07-01T23:30:00Z", rating: 2 });
      addSession(sql, { id: "new", recipe_id: demo.id, started_at: "2026-11-05T18:00:00Z", rating: 5 });
      expect(listCooks(sql)).toEqual([
        { session_id: "new", recipe_id: demo.id, recipe_title: demo.title, started_at: "2026-11-05T18:00:00Z", ended_at: "2026-11-06T19:00:00Z", date: "2026-11-05", rating: 5, summary: null, reflection_status: "pending" },
        { session_id: "old", recipe_id: demo.id, recipe_title: demo.title, started_at: "2026-07-01T23:30:00Z", ended_at: "2026-11-06T19:00:00Z", date: "2026-07-02", rating: 2, summary: null, reflection_status: "pending" },
      ]);
    });
  });

  it("leaves out sessions that were never ended", async () => {
    await inBrain("history_unended", (sql) => {
      addSession(sql, { id: "abandoned", started_at: "2026-11-06T18:00:00Z", ended_at: null });
      expect(listCooks(sql)).toEqual([]);
    });
  });

  it("uses the reflection's rating and summary when the cook gave no rating of their own", async () => {
    await inBrain("history_reflection", (sql) => {
      addSession(sql, { id: "own", started_at: "2026-11-01T18:00:00Z", rating: 4, reflection: { rating: 4, summary: "Lovely." }, reflected_at: "2026-11-01T19:00:00Z" });
      addSession(sql, { id: "inferred", started_at: "2026-11-02T18:00:00Z", reflection: { rating: 3, summary: "Fine." }, reflected_at: "2026-11-02T19:00:00Z" });
      addSession(sql, { id: "unsure", started_at: "2026-11-03T18:00:00Z", reflection: { rating: null, summary: "Hard to say." }, reflected_at: "2026-11-03T19:00:00Z" });
      const cooks = Object.fromEntries(listCooks(sql).map((c) => [c.session_id, c]));
      expect(cooks.own).toMatchObject({ rating: 4, summary: "Lovely.", reflection_status: "done" });
      expect(cooks.inferred).toMatchObject({ rating: 3, summary: "Fine.", reflection_status: "done" });
      expect(cooks.unsure).toMatchObject({ rating: null, summary: "Hard to say.", reflection_status: "done" });
    });
  });

  it("keeps cooks whose recipe has gone, and reports failed reflections", async () => {
    await inBrain("history_gone", (sql) => {
      addSession(sql, { id: "gone", recipe_id: "deleted-recipe", started_at: "2026-11-01T18:00:00Z", rating: 1, reflection_error: "Claude declined." });
      expect(listCooks(sql)).toEqual([expect.objectContaining({ session_id: "gone", recipe_id: "deleted-recipe", recipe_title: null, rating: 1, reflection_status: "failed" })]);
    });
  });

  it("caps the list at the newest cooks", async () => {
    await inBrain("history_cap", (sql) => {
      for (let n = 0; n < MAX_HISTORY + 5; n++) {
        addSession(sql, { id: `s${n}`, started_at: new Date(Date.UTC(2026, 0, 1, 0, n)).toISOString() });
      }
      const cooks = listCooks(sql);
      expect(cooks).toHaveLength(MAX_HISTORY);
      expect(cooks[0].session_id).toBe(`s${MAX_HISTORY + 4}`);
    });
  });
});
