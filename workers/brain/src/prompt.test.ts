import type { Recipe } from "@sous/contracts";
import { describe, expect, it } from "vitest";
import { assembleContext, openingLine, STAGE_PROMPT, type ContextSources } from "./prompt";
import { demoRecipe } from "./seed";
import { PHONE_PREFIX } from "./sessions";

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

  it("is Sous, never Sou, and calls the cook Chef", () => {
    expect(STAGE_PROMPT).toMatch(/^You are Sous,/);
    expect(STAGE_PROMPT).not.toMatch(/\bSou\b/);
    expect(STAGE_PROMPT).toMatch(/always call them "Chef"/);
  });

  it("gives one instruction per sentence, offers rather than tells, and never says you should", () => {
    expect(STAGE_PROMPT).toContain("One instruction per sentence");
    expect(STAGE_PROMPT).toContain('"Chef, the recipe says twelve minutes. Set it?"');
    expect(STAGE_PROMPT).toMatch(/Never say "you should"/);
    expect(STAGE_PROMPT.replace(/Never say "you should"/, "")).not.toMatch(/you should/i);
  });

  it("treats a bare acknowledgement as closing the instruction, and an addition as a new one", () => {
    for (const ack of ['"Heard"', '"Yes, Chef"', '"Got it"']) expect(STAGE_PROMPT).toContain(ack);
    expect(STAGE_PROMPT).toMatch(/say nothing at all/);
    expect(STAGE_PROMPT).toMatch(/"Yep, but make it ten", is a new instruction/);
  });

  it("asks for await_ack with a short form whenever a reply ends with an instruction or offer", () => {
    expect(STAGE_PROMPT).toMatch(/call await_ack once, last, with a short form/);
    expect(STAGE_PROMPT).toContain('"Chef, rice, twelve minutes. Heard?"');
  });

  it("never speaks first, and leads with what it needs when the phone says why the chef opened a turn", () => {
    expect(STAGE_PROMPT).toContain("You never speak first.");
    expect(STAGE_PROMPT).toContain(`"${PHONE_PREFIX}" comes from the phone, not the chef`);
    expect(STAGE_PROMPT).toMatch(/never cancel it/);
  });

  it("numbers choices out loud so the chef can pick one by voice", () => {
    expect(STAGE_PROMPT).toMatch(/number them out loud/);
    expect(STAGE_PROMPT).toContain('"number two"');
  });

  it("knows stop words only stop the talking", () => {
    expect(STAGE_PROMPT).toMatch(/"Hold", "Wait" and "Stop" only mean stop talking\. Never cancel a timer/);
  });
});

describe("openingLine", () => {
  it("calls the recipe back like a kitchen and offers the ingredients", () => {
    expect(openingLine(recipe)).toBe(`Heard, Chef. ${recipe.title}. Shall I read you the ingredients first?`);
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
