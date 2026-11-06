import { describe, expect, it } from "vitest";
import { fromRow, slugify, toRow, validateRecipe } from "./recipes";
import { demoRecipe } from "./seed";

describe("slugify", () => {
  it("makes a URL and filename safe slug", () => {
    expect(slugify("Miso Salmon")).toBe("miso-salmon");
    expect(slugify("  Crème Brûlée!! (the easy one) ")).toBe("creme-brulee-the-easy-one");
    expect(slugify("🍜🍜")).toBe("recipe");
    expect(slugify("a".repeat(80))).toHaveLength(60);
  });
});

describe("validateRecipe", () => {
  it("accepts the demo recipe and drops fields the brain owns", () => {
    const result = validateRecipe({ ...demoRecipe, id: "x", slug: "x", created_at: "2026-11-06T12:00:00Z", updated_at: "2026-11-06T12:00:00Z" });
    expect(result).toEqual({ ok: true, recipe: demoRecipe });
  });

  it("explains what's wrong with a broken recipe", () => {
    const result = validateRecipe({ title: "", ingredients: [{ quantity: -1 }], steps: [], user_id: "user_x" });
    expect(result.ok).toBe(false);
    if (result.ok) return;
    const paths = result.issues.map((i) => i.path);
    expect(paths).toEqual(expect.arrayContaining(["#/title", "#/steps", "#/ingredients/0"]));
  });

  it("rejects a source_url that isn't a URL", () => {
    expect(validateRecipe({ ...demoRecipe, source_url: "not a url" }).ok).toBe(false);
  });
});

describe("rows", () => {
  it("round-trips a recipe through its storage row", () => {
    const row = toRow(demoRecipe, "id-1", "fake-demo-cheese-toastie", "2026-11-06T12:00:00.000Z");
    expect(row.title).toBe(demoRecipe.title);
    expect(JSON.parse(row.data)).not.toHaveProperty("title");
    expect(fromRow(row)).toEqual({
      ...demoRecipe,
      id: "id-1",
      slug: "fake-demo-cheese-toastie",
      created_at: "2026-11-06T12:00:00.000Z",
      updated_at: "2026-11-06T12:00:00.000Z",
    });
  });

  it("leaves source_url out when there isn't one", () => {
    const { source_url, ...withoutSource } = demoRecipe;
    expect(fromRow(toRow(withoutSource, "id-2", "s", "2026-11-06T12:00:00.000Z"))).not.toHaveProperty("source_url");
  });
});
