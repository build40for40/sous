import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { UserBrain } from "./brain";
import { buildDigest, MAX_CANDIDATES, readDigest, renderDigest, type CookRecord, type GraphInput, type TopicLink } from "./digest";
import { recipeNotePath } from "./prompt";
import type { Reflection } from "./reflection";
import { writeReflection } from "./vault";

const today = new Date("2026-11-06T12:00:00Z");
const user = { preferences: { units: "metric" }, about: "# About me\n\nHates coriander." };

const recipe = (id: string, title = `Fake ${id}`) => ({ id, title });
const cook = (recipe_id: string, day: string, rating: number | null): CookRecord => ({ recipe_id, started_at: `2026-10-${day}T18:00:00Z`, rating });
const link = (kind: TopicLink["kind"], name: string, rating: number | null): TopicLink => ({ kind, path: `${kind}s/${name}.md`, name, rating });

const graph = (overrides: Partial<GraphInput> = {}): GraphInput => ({
  today,
  user,
  recipes: [],
  cooks: [],
  topicLinks: [],
  details: () => ({ ingredients: ["salt"], total_minutes: 20 }),
  ...overrides,
});

describe("buildDigest", () => {
  it("counts cooks, last cooked and ratings for each recipe", () => {
    const { candidates } = buildDigest(graph({ recipes: [recipe("a")], cooks: [cook("a", "02", 4), cook("a", "20", 5), cook("a", "10", null)] }));
    expect(candidates).toEqual([
      { id: "a", title: "Fake a", ingredients: ["salt"], total_minutes: 20, times_cooked: 3, last_cooked: "2026-10-20", average_rating: 4.5, latest_rating: 5 },
    ]);
  });

  it("takes a recipe off the table while its latest rating is bad, and lists it separately", () => {
    const digest = buildDigest(graph({ recipes: [recipe("bad"), recipe("loved")], cooks: [cook("bad", "01", 5), cook("bad", "08", 1), cook("loved", "03", 5)] }));
    expect(digest.candidates.map((c) => c.id)).toEqual(["loved"]);
    expect(digest.rated_badly).toEqual([{ title: "Fake bad", latest_rating: 1 }]);
  });

  it("brings a badly rated recipe back once the cook rates it well again", () => {
    const digest = buildDigest(graph({ recipes: [recipe("redeemed")], cooks: [cook("redeemed", "01", 1), cook("redeemed", "15", 4)] }));
    expect(digest.candidates.map((c) => c.id)).toEqual(["redeemed"]);
    expect(digest.rated_badly).toEqual([]);
  });

  it("keeps recipes with no rating on offer, and ignores unrated cooks when judging", () => {
    const digest = buildDigest(graph({ recipes: [recipe("unrated"), recipe("fresh")], cooks: [cook("unrated", "01", null)] }));
    expect(digest.candidates.map((c) => c.id)).toEqual(["fresh", "unrated"]);
    expect(digest.candidates[1]).toMatchObject({ times_cooked: 1, average_rating: null, latest_rating: null });
  });

  it("puts loved recipes first, best average first, then never cooked in the given order, then the rest", () => {
    const digest = buildDigest(
      graph({
        recipes: [recipe("middling"), recipe("new-1"), recipe("good"), recipe("new-2"), recipe("great")],
        cooks: [cook("middling", "01", 3), cook("good", "01", 4), cook("great", "01", 5)],
      }),
    );
    expect(digest.candidates.map((c) => c.id)).toEqual(["great", "good", "new-1", "new-2", "middling"]);
  });

  it("caps the candidates", () => {
    const recipes = Array.from({ length: MAX_CANDIDATES + 30 }, (_, n) => recipe(`r${n}`));
    expect(buildDigest(graph({ recipes })).candidates).toHaveLength(MAX_CANDIDATES);
  });

  it("works out favourite and avoided ingredients and techniques to practise from link counts", () => {
    const digest = buildDigest(
      graph({
        topicLinks: [
          link("ingredient", "miso", 5),
          link("ingredient", "miso", 4),
          link("ingredient", "salmon", 5),
          link("ingredient", "coriander", 1),
          link("ingredient", "coriander", 2),
          link("ingredient", "rice", 5),
          link("ingredient", "rice", 1),
          link("ingredient", "unrated", null),
          link("technique", "toasting", 5),
          link("technique", "frying", 2),
          link("technique", "frying", 3),
          link("technique", "poaching", null),
        ],
      }),
    );
    expect(digest.favourite_ingredients).toEqual([
      { name: "miso", cooks: 2, loved: 2, poor: 0, average_rating: 4.5 },
      { name: "salmon", cooks: 1, loved: 1, poor: 0, average_rating: 5 },
    ]);
    expect(digest.avoided_ingredients).toEqual([
      { name: "coriander", cooks: 2, loved: 0, poor: 2, average_rating: 1.5 },
      { name: "rice", cooks: 2, loved: 1, poor: 1, average_rating: 3 },
    ]);
    expect(digest.techniques_to_practise).toEqual([{ name: "frying", cooks: 2, loved: 0, poor: 1, average_rating: 2.5 }]);
  });

  it("names a topic from its path when it has no name, trims USER.md and gives today's London date", () => {
    const digest = buildDigest(
      graph({
        today: new Date("2026-07-01T23:30:00Z"),
        user: { preferences: {}, about: `  ${"x".repeat(5_000)}  ` },
        topicLinks: [{ kind: "ingredient", path: "ingredients/spring-onion.md", name: null, rating: 5 }],
      }),
    );
    expect(digest.favourite_ingredients[0].name).toBe("spring onion");
    expect(digest.user.about).toHaveLength(4_000);
    expect(digest.today).toBe("2026-07-02");
  });
});

describe("renderDigest", () => {
  it("writes every part of the digest the model reads", () => {
    const text = renderDigest(
      buildDigest(
        graph({
          recipes: [recipe("loved-1", "Fake Miso Salmon"), recipe("bad-1", "Fake Coriander Curry"), recipe("new-1", "Fake Pancakes")],
          cooks: [cook("loved-1", "01", 5), cook("loved-1", "09", 4), cook("bad-1", "05", 1)],
          topicLinks: [link("ingredient", "miso", 5), link("ingredient", "coriander", 1), link("technique", "frying", 2)],
        }),
      ),
    );
    for (const expected of [
      "Today is 2026-11-06.",
      "Hates coriander.",
      "- miso: 1 cook, 1 loved, 0 rated badly",
      "- coriander: 1 cook, 0 loved, 1 rated badly",
      "- frying: 1 cook, 0 loved, 1 rated badly",
      "- Fake Coriander Curry, latest rating 1/5",
      "- id=loved-1 | Fake Miso Salmon | cooked 2 times, last 2026-10-09, average 4.5/5, latest 4/5 | 20 minutes | ingredients: salt",
      "- id=new-1 | Fake Pancakes | never cooked | 20 minutes | ingredients: salt",
    ]) {
      expect(text).toContain(expected);
    }
    expect(text).not.toContain("id=bad-1");
    expect(text.indexOf("id=loved-1")).toBeLessThan(text.indexOf("id=new-1"));
  });

  it("says so when there is nothing yet", () => {
    const text = renderDigest(buildDigest(graph()));
    expect(text).toContain("None yet.");
    expect(text).toContain("# Saved recipes on offer\n\nNone.");
  });
});

describe("readDigest", () => {
  const reflection = (rating: number, ingredients: string[], techniques: string[]): Reflection => ({
    rating: rating as Reflection["rating"],
    summary: "A cook.",
    worked: [],
    failed: [],
    substitutions: [],
    preferences: [],
    ingredients,
    techniques,
    cuisine: null,
  });

  it("reads recipes, finished sessions and the vault's links out of the user's SQLite", async () => {
    const stub = env.USER_BRAIN.get(env.USER_BRAIN.idFromName("digest_read"));
    const digest = await runInDurableObject(stub, (brain: UserBrain, state) => {
      const sql = state.storage.sql;
      const salmon = brain.createRecipe({ title: "Fake Miso Salmon", ingredients: [{ name: "miso" }, { name: "salmon" }], steps: [{ text: "Roast." }], times: { total_minutes: 25 } });
      const curry = brain.createRecipe({ title: "Fake Coriander Curry", ingredients: [{ name: "coriander" }], steps: [{ text: "Simmer." }] });
      const cooked = (id: string, recipe: typeof salmon, day: string, rating: number, ingredients: string[], techniques: string[]) => {
        const startedAt = `2026-11-${day}T18:00:00Z`;
        sql.exec("INSERT INTO sessions (id, recipe_id, started_at, ended_at, rating) VALUES (?, ?, ?, ?, ?)", id, recipe.id, startedAt, startedAt, rating);
        writeReflection(sql, { id, started_at: startedAt, recipe, notes: null, reflection: reflection(rating, ingredients, techniques) }, startedAt);
      };
      cooked("aaaaaaaa-1", salmon, "01", 5, ["miso", "salmon"], ["roasting"]);
      cooked("bbbbbbbb-2", curry, "02", 1, ["coriander"], ["simmering"]);
      sql.exec("INSERT INTO sessions (id, recipe_id, started_at) VALUES ('unfinished', ?, '2026-11-03T18:00:00Z')", curry.id);
      expect(sql.exec("SELECT 1 FROM files WHERE path = ?", recipeNotePath(salmon.slug!)).toArray()).toHaveLength(1);
      return readDigest(sql, brain.getProfile(), today);
    });

    expect(digest.candidates.map((c) => ({ title: c.title, times_cooked: c.times_cooked, latest_rating: c.latest_rating, ingredients: c.ingredients, total_minutes: c.total_minutes }))).toEqual([
      { title: "Fake Miso Salmon", times_cooked: 1, latest_rating: 5, ingredients: ["miso", "salmon"], total_minutes: 25 },
      { title: "Fake Demo Cheese Toastie", times_cooked: 0, latest_rating: null, ingredients: ["bread", "butter", "cheddar"], total_minutes: 8 },
    ]);
    expect(digest.rated_badly).toEqual([{ title: "Fake Coriander Curry", latest_rating: 1 }]);
    expect(digest.favourite_ingredients.map((t) => t.name)).toEqual(["miso", "salmon"]);
    expect(digest.avoided_ingredients.map((t) => t.name)).toEqual(["coriander"]);
    expect(digest.techniques_to_practise.map((t) => t.name)).toEqual(["simmering"]);
    expect(digest.user.about).toContain("Sous fills this in");
  });
});
