import Ajv2020 from "ajv/dist/2020";
import addFormats from "ajv-formats";
import { describe, expect, it } from "vitest";
import example from "../examples/recipe.json";
import { type Recipe, recipeSchema } from "./recipe";

const ajv = new Ajv2020({ strict: true, allErrors: true });
addFormats(ajv);
const validate = ajv.compile<Recipe>(recipeSchema);

const typedExample: Recipe = example;

function broken(change: (recipe: Recipe) => void): Recipe {
  const recipe = structuredClone(typedExample);
  change(recipe);
  return recipe;
}

describe("recipe schema", () => {
  it("accepts the example recipe", () => {
    expect(validate(example), JSON.stringify(validate.errors)).toBe(true);
  });

  it("accepts a fresh recipe from extraction with only the required fields", () => {
    const fresh: Recipe = {
      title: "Fake Toast",
      ingredients: [{ name: "bread" }],
      steps: [{ text: "Toast it." }],
    };
    expect(validate(fresh), JSON.stringify(validate.errors)).toBe(true);
  });

  it.each<[string, (recipe: Recipe) => void]>([
    ["no title", (r) => delete (r as Partial<Recipe>).title],
    ["an empty title", (r) => (r.title = "")],
    ["no ingredients", (r) => (r.ingredients = [])],
    ["no steps", (r) => (r.steps = [])],
    ["an ingredient without a name", (r) => delete (r.ingredients[0] as Partial<Recipe["ingredients"][0]>).name],
    ["a zero quantity", (r) => (r.ingredients[0].quantity = 0)],
    ["a quantity written as text", (r) => ((r.ingredients[0] as unknown as Record<string, unknown>).quantity = "two")],
    ["a step without text", (r) => delete (r.steps[0] as Partial<Recipe["steps"][0]>).text],
    ["an empty done cue", (r) => (r.steps[0].done_cue = "")],
    ["a fractional step duration", (r) => (r.steps[0].duration_seconds = 1.5)],
    ["negative minutes", (r) => (r.times = { cook_minutes: -1 })],
    ["zero servings", (r) => (r.servings = 0)],
    ["a source that isn't a URL", (r) => (r.source_url = "not a url")],
    ["a slug with spaces", (r) => (r.slug = "beans on toast")],
    ["an unknown field", (r) => ((r as unknown as Record<string, unknown>).cuisine = "british")],
  ])("rejects a recipe with %s", (_, change) => {
    expect(validate(broken(change))).toBe(false);
  });
});
