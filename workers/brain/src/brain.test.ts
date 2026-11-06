import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { UserBrain } from "./brain";
import { SCHEMA_VERSION } from "./schema";
import { demoRecipe } from "./seed";

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
});
