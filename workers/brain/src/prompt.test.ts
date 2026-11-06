import type { Recipe } from "@sous/contracts";
import { describe, expect, it } from "vitest";
import { assembleContext, openingLine, STAGE_PROMPT, type ContextSources } from "./prompt";
import { demoRecipe } from "./seed";

const recipe: Recipe = { ...demoRecipe, id: "recipe-1", slug: "fake-demo-cheese-toastie", created_at: "2026-11-06T12:00:00Z", updated_at: "2026-11-06T12:00:00Z" };

const sources: ContextSources = {
  user: { preferences: { avoid: ["coriander"] }, about: "# About me\n\nOne frying pan, big appetite." },
  memory: "Likes a timer for anything over two minutes.",
  recipe,
  recipeNote: { path: "recipes/fake-demo-cheese-toastie.md", frontmatter: '{"rating":4}', body: "Links [[cheddar]] and [[toasting]]." },
  sessionNotes: [
    { path: "sessions/b.md", frontmatter: "{}", body: "Burnt the second side." },
    { path: "sessions/a.md", frontmatter: "{}", body: "Perfect first try." },
  ],
  linkedNotes: [{ path: "ingredients/cheddar.md", frontmatter: "{}", body: "Grate it fine so it melts before the bread burns." }],
  openingLine: openingLine(recipe),
};

describe("STAGE_PROMPT", () => {
  it("asks for speech-ready replies with numbers and units as words", () => {
    expect(STAGE_PROMPT).toMatch(/numbers?.*as words/i);
    expect(STAGE_PROMPT).toContain("two tablespoons");
  });

  it("sets out the stages and every tool", () => {
    for (const word of ["decide", "prep", "cook", "present", "feedback", "set_stage", "go_to_step", "start_timer", "cancel_timer", "show", "note"]) {
      expect(STAGE_PROMPT).toContain(word);
    }
  });

  it("practises what it preaches: no digits", () => {
    expect(STAGE_PROMPT).not.toMatch(/[0-9]/);
  });
});

describe("openingLine", () => {
  it("names the recipe", () => {
    expect(openingLine(recipe)).toContain(recipe.title);
  });
});

describe("assembleContext", () => {
  it("includes the profile, memory, recipe, its note, its last cooks, linked notes and the greeting, in that order", () => {
    const context = assembleContext(sources);
    const order = [
      "# USER.md",
      '"avoid":["coriander"]',
      "One frying pan",
      "# MEMORY.md",
      "Likes a timer",
      "# The recipe",
      '"title": "Fake Demo Cheese Toastie"',
      "# Your note on this recipe",
      '## recipes/fake-demo-cheese-toastie.md\nfrontmatter: {"rating":4}',
      "# Their last cooks",
      "Burnt the second side.",
      "Perfect first try.",
      "# Notes this recipe links to",
      "## ingredients/cheddar.md\nGrate it fine",
      "# This session",
      sources.openingLine,
    ];
    const positions = order.map((text) => context.indexOf(text));
    expect(positions.every((p) => p >= 0)).toBe(true);
    expect([...positions].sort((a, b) => a - b)).toEqual(positions);
  });

  it("leaves out the fields the brain owns", () => {
    const context = assembleContext(sources);
    expect(context).not.toContain("recipe-1");
    expect(context).not.toContain("created_at");
  });

  it("says so when there's nothing remembered yet", () => {
    const context = assembleContext({ ...sources, memory: null, recipeNote: null, sessionNotes: [], linkedNotes: [] });
    expect(context).toContain("# MEMORY.md\n\nNothing yet.");
    expect(context).toContain("first time you've cooked it together");
  });

  it("cuts very long notes short", () => {
    const context = assembleContext({ ...sources, linkedNotes: [{ path: "techniques/long.md", frontmatter: "{}", body: "x".repeat(10_000) }] });
    expect(context).toContain("[cut short]");
    expect(context).not.toContain("x".repeat(6_001));
  });

  it("is the same every time for the same sources, so it caches", () => {
    expect(assembleContext(sources)).toBe(assembleContext(structuredClone(sources)));
  });
});
