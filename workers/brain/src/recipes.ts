import { Validator, type Schema } from "@cfworker/json-schema";
import { recipeSchema, type Recipe } from "@sous/contracts";

export type NewRecipe = Omit<Recipe, "id" | "slug" | "created_at" | "updated_at">;

export interface RecipeRow extends Record<string, SqlStorageValue> {
  id: string;
  slug: string;
  source_url: string | null;
  title: string;
  data: string;
  created_at: string;
  updated_at: string;
}

export interface ValidationIssue {
  path: string;
  message: string;
}

export type RecipeValidation = { ok: true; recipe: NewRecipe } | { ok: false; issues: ValidationIssue[] };

const validator = new Validator(recipeSchema as unknown as Schema, "2020-12", false);

export function validateRecipe(input: unknown): RecipeValidation {
  const result = validator.validate(input);
  if (!result.valid) {
    const issues = result.errors
      .filter((e) => !["$ref", "properties", "items", "allOf"].includes(e.keyword))
      .slice(0, 20)
      .map((e) => ({ path: e.instanceLocation, message: e.error }));
    return { ok: false, issues };
  }
  const { id, slug, created_at, updated_at, ...recipe } = input as Recipe;
  return { ok: true, recipe };
}

export function slugify(title: string): string {
  const slug = title
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .slice(0, 60)
    .replace(/^-+|-+$/g, "");
  return slug || "recipe";
}

export function toRow(recipe: NewRecipe, id: string, slug: string, now: string): RecipeRow {
  const { title, source_url, ...data } = recipe;
  return { id, slug, source_url: source_url ?? null, title, data: JSON.stringify(data), created_at: now, updated_at: now };
}

export function fromRow(row: RecipeRow): Recipe {
  const data = JSON.parse(row.data) as Omit<Recipe, "id" | "slug" | "title" | "source_url">;
  return {
    id: row.id,
    slug: row.slug,
    title: row.title,
    ...(row.source_url ? { source_url: row.source_url } : {}),
    ...data,
    created_at: row.created_at,
    updated_at: row.updated_at,
  };
}
