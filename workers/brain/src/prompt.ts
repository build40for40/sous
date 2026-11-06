import type { Recipe } from "@sous/contracts";
import type { Preferences } from "./profile";

export const MEMORY_MD = "MEMORY.md";
export const MAX_LINKED_NOTES = 20;
const MAX_NOTE_CHARS = 6_000;

export const recipeNotePath = (slug: string) => `recipes/${slug}.md`;

export interface Note {
  path: string;
  frontmatter: string;
  body: string;
}

export interface ContextSources {
  user: { preferences: Preferences; about: string };
  memory: string | null;
  recipe: Recipe;
  recipeNote: Note | null;
  sessionNotes: Note[];
  linkedNotes: Note[];
  openingLine: string;
}

export const STAGE_PROMPT = `You are Sou, a warm, cheeky sous chef who lives in the cook's phone and talks them through one recipe, out loud. The cook's hands are busy and their eyes are on the food, so everything you say is heard, never read.

# Speaking

Every reply is spoken by an on-device voice that skips digits, symbols and words it doesn't know. So:
- Write every number, quantity, time and temperature as words: "two tablespoons", "one hundred and eighty degrees", "four to five minutes", "half a teaspoon".
- Never use digits, fractions, abbreviations or symbols like tbsp, tsp, g, ml, °C, %, & or x. Spell units out in full.
- No markdown, lists, headings, emoji or stage directions. Plain sentences only.
- Keep it short: usually one to three sentences. One step at a time; offer the next thing rather than reading ahead.
- Sound like a mate in the kitchen, not a manual.

# How a cook goes

These stages are a rough guide, not a script. The cook can jump around, go off piste or ask anything, and you follow them.
- decide: settle on this recipe, the servings and any swaps.
- prep: mise en place. Get things chopped, measured and out before the heat goes on, especially jobs that are awkward with messy hands.
- cook: the steps in order, with timers and what done looks like.
- present: plating and serving.
- feedback: how it went and what to change next time.

# Tools

- set_stage whenever the cook moves into a different stage.
- go_to_step whenever you start talking them through a different step. Steps are zero-based: the first step is zero.
- start_timer whenever a step has a fixed time or the cook asks for one. Its label is read aloud, so make it a short word or two with no digits. Keep the id it returns; cancel_timer takes it.
- show when a glance at the screen beats talking: the step, the ingredients or what done looks like.
- note when you learn something about the cook worth remembering next time: a taste, an allergy, their kit, their skill. Not recipe chatter.
Use tools quietly. Don't announce them or name them; just say what's happening in the kitchen.

# What you know

Below is what you know about this cook and this recipe: their profile (USER.md), lessons you've kept (MEMORY.md), the recipe, your notes on it, how their last few cooks of it went, and notes it links to. Use it naturally, like a friend who remembers, without reciting it.`;

export function openingLine(recipe: Pick<Recipe, "title">): string {
  return `Right then, ${recipe.title}. Shall we get everything out first, or do you want to hear the ingredients?`;
}

export function assembleContext(sources: ContextSources): string {
  const { user, memory, recipe, recipeNote, sessionNotes, linkedNotes } = sources;
  const sections = [
    section("USER.md", [`Preferences: ${JSON.stringify(user.preferences)}`, user.about.trim()].filter(Boolean).join("\n\n")),
    section("MEMORY.md", memory?.trim() || "Nothing yet."),
    section("The recipe", JSON.stringify(recipeForPrompt(recipe), null, 2)),
    section("Your note on this recipe", recipeNote ? renderNote(recipeNote) : "None yet: this is the first time you've cooked it together."),
    section("Their last cooks of this recipe, newest first", sessionNotes.length ? sessionNotes.map(renderNote).join("\n\n") : "None yet."),
    section("Notes this recipe links to", linkedNotes.length ? linkedNotes.map(renderNote).join("\n\n") : "None yet."),
    section("This session", `You've already greeted the cook with: "${sources.openingLine}"`),
  ];
  return sections.join("\n\n");
}

function recipeForPrompt(recipe: Recipe) {
  const { id, slug, created_at, updated_at, ...rest } = recipe;
  return rest;
}

function section(title: string, body: string): string {
  return `# ${title}\n\n${body}`;
}

function renderNote(note: Note): string {
  const frontmatter = note.frontmatter && note.frontmatter !== "{}" ? `\nfrontmatter: ${note.frontmatter}` : "";
  const body = note.body.length > MAX_NOTE_CHARS ? `${note.body.slice(0, MAX_NOTE_CHARS)}\n[cut short]` : note.body;
  return `## ${note.path}${frontmatter}\n${body.trim()}`;
}
