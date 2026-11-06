import type { Recipe } from "@sous/contracts";
import type { Preferences } from "./profile";
import { londonDate } from "./vault";

export const MAX_CANDIDATES = 120;
export const MAX_TOPICS = 10;
export const MAX_REFUSED = 20;
const MAX_RECIPE_INGREDIENTS = 12;
const MAX_ABOUT = 4_000;
const LOVED_AT_LEAST = 4;
const BAD_AT_MOST = 2;

export interface RecipeSummary {
  id: string;
  title: string;
}

export interface RecipeDetails {
  ingredients: string[];
  total_minutes: number | null;
}

export interface CookRecord {
  recipe_id: string;
  started_at: string;
  rating: number | null;
}

/** One session note linking to one ingredient or technique note, with the rating that session was given. */
export interface TopicLink {
  kind: "ingredient" | "technique";
  path: string;
  name: string | null;
  rating: number | null;
}

export interface GraphInput {
  today: Date;
  user: { preferences: Preferences; about: string };
  recipes: RecipeSummary[];
  cooks: CookRecord[];
  topicLinks: TopicLink[];
  details: (recipeId: string) => RecipeDetails;
}

export interface Candidate extends RecipeSummary, RecipeDetails {
  times_cooked: number;
  last_cooked: string | null;
  average_rating: number | null;
  latest_rating: number | null;
}

export interface TopicStat {
  name: string;
  cooks: number;
  loved: number;
  poor: number;
  average_rating: number | null;
}

export interface Digest {
  today: string;
  user: { preferences: Preferences; about: string };
  candidates: Candidate[];
  rated_badly: { title: string; latest_rating: number }[];
  favourite_ingredients: TopicStat[];
  avoided_ingredients: TopicStat[];
  techniques_to_practise: TopicStat[];
}

interface RecipeRow extends Record<string, SqlStorageValue> {
  id: string;
  title: string;
}

interface CookRow extends Record<string, SqlStorageValue> {
  recipe_id: string;
  started_at: string;
  rating: number | null;
}

interface TopicRow extends Record<string, SqlStorageValue> {
  kind: "ingredient" | "technique";
  path: string;
  name: string | null;
  rating: number | null;
}

const mean = (numbers: number[]) => (numbers.length ? Math.round((numbers.reduce((a, b) => a + b, 0) / numbers.length) * 10) / 10 : null);

/** Boils the graph down to what the model needs to pick a recipe, in a stable order. A recipe whose most recent rating is bad is left off the candidates. */
export function buildDigest({ today, user, recipes, cooks, topicLinks, details }: GraphInput): Digest {
  const cooksByRecipe = new Map<string, CookRecord[]>();
  for (const cook of [...cooks].sort((a, b) => a.started_at.localeCompare(b.started_at))) {
    cooksByRecipe.set(cook.recipe_id, [...(cooksByRecipe.get(cook.recipe_id) ?? []), cook]);
  }

  const candidates: Candidate[] = [];
  const ratedBadly: Digest["rated_badly"] = [];
  for (const recipe of recipes) {
    const history = cooksByRecipe.get(recipe.id) ?? [];
    const ratings = history.flatMap((c) => (c.rating === null ? [] : [c.rating]));
    const latest = ratings.at(-1) ?? null;
    if (latest !== null && latest <= BAD_AT_MOST) {
      ratedBadly.push({ title: recipe.title, latest_rating: latest });
      continue;
    }
    candidates.push({
      ...recipe,
      ...details(recipe.id),
      times_cooked: history.length,
      last_cooked: history.length ? londonDate(history[history.length - 1].started_at) : null,
      average_rating: mean(ratings),
      latest_rating: latest,
    });
  }

  const tier = (c: Candidate) => (c.latest_rating !== null && c.latest_rating >= LOVED_AT_LEAST ? 0 : c.times_cooked === 0 ? 1 : 2);
  const ordered = candidates
    .map((c, index) => ({ c, index }))
    .sort((a, b) => {
      const byTier = tier(a.c) - tier(b.c);
      if (byTier) return byTier;
      if (tier(a.c) === 0) return (b.c.average_rating ?? 0) - (a.c.average_rating ?? 0) || a.index - b.index;
      return a.index - b.index;
    })
    .map(({ c }) => c);

  const ingredients = topicStats(topicLinks, "ingredient");
  const techniques = topicStats(topicLinks, "technique");
  const byName = (a: TopicStat, b: TopicStat) => a.name.localeCompare(b.name);

  return {
    today: londonDate(today.toISOString()),
    user: { preferences: user.preferences, about: user.about.trim().slice(0, MAX_ABOUT) },
    candidates: ordered.slice(0, MAX_CANDIDATES),
    rated_badly: ratedBadly.slice(0, MAX_REFUSED),
    favourite_ingredients: ingredients
      .filter((t) => t.loved > 0 && t.loved > t.poor)
      .sort((a, b) => b.loved - a.loved || b.cooks - a.cooks || byName(a, b))
      .slice(0, MAX_TOPICS),
    avoided_ingredients: ingredients
      .filter((t) => t.poor > 0 && t.poor >= t.loved)
      .sort((a, b) => b.poor - a.poor || b.cooks - a.cooks || byName(a, b))
      .slice(0, MAX_TOPICS),
    techniques_to_practise: techniques
      .filter((t) => t.average_rating !== null && t.average_rating < LOVED_AT_LEAST)
      .sort((a, b) => a.average_rating! - b.average_rating! || b.cooks - a.cooks || byName(a, b))
      .slice(0, MAX_TOPICS),
  };
}

/** One entry per ingredient or technique, counting the cook sessions that link to it. */
function topicStats(links: TopicLink[], kind: TopicLink["kind"]): TopicStat[] {
  const byPath = new Map<string, { name: string; ratings: number[]; cooks: number }>();
  for (const link of links.filter((l) => l.kind === kind)) {
    const entry = byPath.get(link.path) ?? { name: link.name || nameFromPath(link.path), ratings: [], cooks: 0 };
    entry.cooks++;
    if (link.rating !== null) entry.ratings.push(link.rating);
    byPath.set(link.path, entry);
  }
  return [...byPath.values()].map(({ name, ratings, cooks }) => ({
    name,
    cooks,
    loved: ratings.filter((r) => r >= LOVED_AT_LEAST).length,
    poor: ratings.filter((r) => r <= BAD_AT_MOST).length,
    average_rating: mean(ratings),
  }));
}

const nameFromPath = (path: string) => path.replace(/^.*\//, "").replace(/\.md$/, "").replace(/-/g, " ");

/** Reads the digest straight from the user's SQLite: recipes, finished sessions, and the session notes' links into ingredient and technique notes. */
export function readDigest(sql: SqlStorage, user: GraphInput["user"], today: Date): Digest {
  const recipes = sql.exec<RecipeRow>("SELECT id, title FROM recipes ORDER BY created_at DESC, rowid DESC").toArray();
  const cooks = sql
    .exec<CookRow>(
      `SELECT recipe_id, started_at, COALESCE(rating, json_extract(reflection, '$.rating')) AS rating
       FROM sessions WHERE ended_at IS NOT NULL AND recipe_id IS NOT NULL ORDER BY started_at, rowid`,
    )
    .toArray();
  const topicLinks = sql
    .exec<TopicRow>(
      `SELECT f.kind AS kind, f.path AS path, json_extract(f.frontmatter, '$.name') AS name, json_extract(s.frontmatter, '$.rating') AS rating
       FROM links l
       JOIN files f ON f.path = l.dst AND f.kind IN ('ingredient', 'technique')
       JOIN files s ON s.path = l.src AND s.kind = 'session'`,
    )
    .toArray();
  const details = (id: string): RecipeDetails => {
    const row = sql.exec<{ data: string }>("SELECT data FROM recipes WHERE id = ?", id).toArray()[0];
    const data = row ? (JSON.parse(row.data) as Pick<Recipe, "ingredients" | "times">) : null;
    return {
      ingredients: (data?.ingredients ?? []).map((i) => i.name).slice(0, MAX_RECIPE_INGREDIENTS),
      total_minutes: data?.times?.total_minutes ?? null,
    };
  };
  return buildDigest({ today, user, recipes, cooks, topicLinks, details });
}

export function renderDigest(digest: Digest): string {
  const section = (title: string, body: string) => `# ${title}\n\n${body}`;
  const topics = (list: TopicStat[]) =>
    list.length ? list.map((t) => `- ${t.name}: ${t.cooks} ${t.cooks === 1 ? "cook" : "cooks"}, ${t.loved} loved, ${t.poor} rated badly`).join("\n") : "None yet.";
  const candidate = (c: Candidate) =>
    [
      `id=${c.id}`,
      c.title,
      c.times_cooked
        ? `cooked ${c.times_cooked} ${c.times_cooked === 1 ? "time" : "times"}, last ${c.last_cooked}${c.average_rating !== null ? `, average ${c.average_rating}/5, latest ${c.latest_rating}/5` : ", never rated"}`
        : "never cooked",
      ...(c.total_minutes ? [`${c.total_minutes} minutes`] : []),
      ...(c.ingredients.length ? [`ingredients: ${c.ingredients.join(", ")}`] : []),
    ].join(" | ");
  return [
    `Today is ${digest.today}.`,
    section("USER.md", [`Preferences: ${JSON.stringify(digest.user.preferences)}`, digest.user.about].filter(Boolean).join("\n\n")),
    section("Favourite ingredients (from cooks rated 4 or 5)", topics(digest.favourite_ingredients)),
    section("Ingredients to steer clear of (from cooks rated 1 or 2)", topics(digest.avoided_ingredients)),
    section("Techniques to practise (cooked, but never quite nailed)", topics(digest.techniques_to_practise)),
    section(
      "Recipes the cook rated badly (not on offer)",
      digest.rated_badly.length ? digest.rated_badly.map((r) => `- ${r.title}, latest rating ${r.latest_rating}/5`).join("\n") : "None.",
    ),
    section("Saved recipes on offer", digest.candidates.length ? digest.candidates.map((c) => `- ${candidate(c)}`).join("\n") : "None."),
  ].join("\n\n");
}
