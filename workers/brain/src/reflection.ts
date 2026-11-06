import Anthropic from "@anthropic-ai/sdk";
import { Validator, type Schema } from "@cfworker/json-schema";
import type { Recipe, Turn } from "@sous/contracts";
import { HttpError, isPlainObject } from "./http";
import type { Preferences } from "./profile";

export const REFLECTION_MODEL = "claude-opus-5-5";
export const REFLECTION_MAX_TOKENS = 32_000;
const MAX_ITEMS = 20;
const MAX_TEXT = 500;
const MAX_NOTES = 4_000;

export type Rating = 1 | 2 | 3 | 4 | 5;

export interface Substitution {
  original: string;
  replacement: string;
  outcome: string;
}

export interface Reflection {
  rating: Rating | null;
  summary: string;
  worked: string[];
  failed: string[];
  substitutions: Substitution[];
  preferences: string[];
  ingredients: string[];
  techniques: string[];
  cuisine: string | null;
}

export interface EndRequest {
  rating?: Rating;
  notes?: string;
}

export interface ReflectionInput {
  recipe: Recipe | null;
  user: { preferences: Preferences; about: string };
  turns: Turn[];
  facts: string[];
  rating: Rating | null;
  notes: string | null;
}

/** A reflection that will never succeed by retrying: a refusal, or output that doesn't fit the schema. */
export class ReflectionError extends Error {}

const list = (description: string) => ({ type: "array", description, items: { type: "string" } });

export const reflectionSchema = {
  type: "object",
  additionalProperties: false,
  required: ["rating", "summary", "worked", "failed", "substitutions", "preferences", "ingredients", "techniques", "cuisine"],
  properties: {
    rating: {
      description: "The cook's rating from one to five if they gave one, otherwise your best read of how it went, or null if there's no sign either way.",
      anyOf: [{ type: "integer", enum: [1, 2, 3, 4, 5] }, { type: "null" }],
    },
    summary: { type: "string", description: "One or two sentences on how this cook went, written for the cook's own notes." },
    worked: list("What went well, specific enough to repeat next time."),
    failed: list("What went wrong or could be better, each written as advice for next time."),
    substitutions: {
      type: "array",
      description: "Ingredients the cook swapped, and how the swap went.",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["original", "replacement", "outcome"],
        properties: {
          original: { type: "string", description: "The ingredient the recipe asked for." },
          replacement: { type: "string", description: "What the cook used instead." },
          outcome: { type: "string", description: "How it turned out." },
        },
      },
    },
    preferences: list("New, lasting things learned about the cook: tastes, allergies, diet, kit, skill. Leave out anything USER.md already says and anything only about this recipe."),
    ingredients: list("The main ingredients actually used, including replacements, as short lowercase singular names like \"cheddar\" or \"spring onion\"."),
    techniques: list("The cooking techniques involved, as short lowercase names like \"shallow frying\" or \"toasting\"."),
    cuisine: { description: "The cuisine, as one short lowercase name like \"british\" or \"thai\", or null if it has none.", anyOf: [{ type: "string" }, { type: "null" }] },
  },
} as const;

const validator = new Validator(reflectionSchema as unknown as Schema, "2020-12", false);

export const REFLECTION_PROMPT = `You are the memory of Sous, a sous chef who lives in a home cook's phone and talks them through recipes out loud. A cook has just finished. Read what happened and file it away, so the next time this cook is in the kitchen Sous remembers what matters.

You get the recipe, the cook's profile (USER.md), the full transcript between the cook and Sous, the facts Sous noted during the cook, and the cook's own rating and notes if they gave any.

- Only record what the transcript, facts or the cook's notes support. Never invent outcomes, swaps or preferences.
- The cook's own rating and notes outrank anything you infer.
- Keep every item short and concrete, in plain British English, written so it's useful the next time they cook.
- Name ingredients, techniques and the cuisine the same way every time, so notes from different cooks link up.`;

export function parseEndRequest(input: unknown): EndRequest {
  if (!isPlainObject(input)) throw new HttpError(400, "invalid_end", { message: "Send {rating?, notes?}." });
  const unknownKeys = Object.keys(input).filter((k) => k !== "rating" && k !== "notes");
  if (unknownKeys.length) throw new HttpError(400, "invalid_end", { message: `Unknown fields: ${unknownKeys.join(", ")}.` });
  const request: EndRequest = {};
  if (input.rating !== undefined && input.rating !== null) {
    if (!Number.isInteger(input.rating) || (input.rating as number) < 1 || (input.rating as number) > 5) {
      throw new HttpError(400, "invalid_end", { message: "rating must be a whole number from 1 to 5." });
    }
    request.rating = input.rating as Rating;
  }
  if (input.notes !== undefined && input.notes !== null) {
    if (typeof input.notes !== "string" || input.notes.length > MAX_NOTES) {
      throw new HttpError(400, "invalid_end", { message: `notes must be text up to ${MAX_NOTES} characters.` });
    }
    if (input.notes.trim()) request.notes = input.notes.trim();
  }
  return request;
}

export function reflectionRequest(input: ReflectionInput): Anthropic.MessageCreateParamsNonStreaming {
  return {
    model: REFLECTION_MODEL,
    max_tokens: REFLECTION_MAX_TOKENS,
    system: REFLECTION_PROMPT,
    messages: [{ role: "user", content: renderInput(input) }],
    output_config: { effort: "high", format: { type: "json_schema", schema: reflectionSchema as unknown as Record<string, unknown> } },
  };
}

export function renderInput({ recipe, user, turns, facts, rating, notes }: ReflectionInput): string {
  const section = (title: string, body: string) => `# ${title}\n\n${body}`;
  const recipeJson = recipe ? JSON.stringify((({ id, slug, created_at, updated_at, ...rest }) => rest)(recipe), null, 2) : "The recipe has since been deleted.";
  return [
    section("The recipe", recipeJson),
    section("USER.md", [`Preferences: ${JSON.stringify(user.preferences)}`, user.about.trim()].filter(Boolean).join("\n\n")),
    section("Transcript", renderTranscript(turns) || "Nothing was said."),
    section("Facts Sous noted", facts.length ? facts.map((f) => `- ${f}`).join("\n") : "None."),
    section("The cook's rating", rating ? `${rating} out of 5` : "Not given."),
    section("The cook's notes", notes ?? "None."),
  ].join("\n\n");
}

export function renderTranscript(turns: Turn[]): string {
  return turns
    .flatMap((turn) => {
      if (turn.role === "cook") return [`Cook: ${turn.text}`];
      if (turn.role === "sous") {
        return [...(turn.text ? [`Sous: ${turn.text}`] : []), ...(turn.tool_calls ?? []).map((c) => `(Sous used ${c.name} ${JSON.stringify(c.input)})`)];
      }
      return [];
    })
    .join("\n");
}

/** Runs the post-cook reflection: one Opus call whose structured output is checked and tidied before anything is written. */
export async function reflect(client: Anthropic, input: ReflectionInput): Promise<{ reflection: Reflection; usage: Anthropic.Usage }> {
  const message = await client.messages.stream(reflectionRequest(input)).finalMessage();
  if (message.stop_reason === "refusal") throw new ReflectionError("Claude declined to reflect on this cook.");
  if (message.stop_reason === "max_tokens") throw new ReflectionError("The reflection ran out of room.");
  const text = message.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("");
  let output: unknown;
  try {
    output = JSON.parse(text);
  } catch {
    throw new ReflectionError("The reflection wasn't JSON.");
  }
  const result = validator.validate(output);
  if (!result.valid) throw new ReflectionError(`The reflection didn't match the schema: ${result.errors.at(-1)?.error}`);
  return { reflection: tidy(output as Reflection, input.rating), usage: message.usage };
}

/** Whether a failed reflection is worth retrying later. */
export function isRetryable(e: unknown): boolean {
  if (e instanceof ReflectionError) return false;
  if (e instanceof Anthropic.APIError && typeof e.status === "number") return e.status === 408 || e.status === 409 || e.status === 429 || e.status >= 500;
  return true;
}

function tidy(output: Reflection, cookRating: Rating | null): Reflection {
  const text = (s: string) => s.trim().replace(/\s+/g, " ").slice(0, MAX_TEXT);
  const texts = (items: string[]) => [...new Set(items.map(text).filter(Boolean))].slice(0, MAX_ITEMS);
  const name = (s: string) => text(s).toLowerCase();
  const names = (items: string[]) => [...new Set(items.map(name).filter(Boolean))].slice(0, MAX_ITEMS);
  return {
    rating: cookRating ?? output.rating,
    summary: text(output.summary),
    worked: texts(output.worked),
    failed: texts(output.failed),
    substitutions: output.substitutions
      .map((s) => ({ original: name(s.original), replacement: name(s.replacement), outcome: text(s.outcome) }))
      .filter((s) => s.original && s.replacement)
      .slice(0, MAX_ITEMS),
    preferences: texts(output.preferences),
    ingredients: names(output.ingredients),
    techniques: names(output.techniques),
    cuisine: output.cuisine && name(output.cuisine) ? name(output.cuisine) : null,
  };
}
