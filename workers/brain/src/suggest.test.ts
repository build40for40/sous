import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createClient } from "./claude";
import { buildDigest, type CookRecord } from "./digest";
import { MAX_SUGGESTIONS, suggest, SuggestError, suggestRequest, suggestSchema } from "./suggest";
import { mockClaude } from "./testing";

afterEach(() => {
  vi.restoreAllMocks();
});

const cook = (recipe_id: string, rating: number): CookRecord => ({ recipe_id, started_at: "2026-10-20T18:00:00Z", rating });

const digest = (cooks: CookRecord[] = [cook("loved", 5), cook("bad", 1)]) =>
  buildDigest({
    today: new Date("2026-11-06T12:00:00Z"),
    user: { preferences: { units: "metric" }, about: "Hates coriander." },
    recipes: [
      { id: "loved", title: "Fake Miso Salmon" },
      { id: "bad", title: "Fake Coriander Curry" },
      { id: "new", title: "Fake Pancakes" },
    ],
    cooks,
    topicLinks: [],
    details: () => ({ ingredients: ["salt"], total_minutes: null }),
  });

const reply = (suggestions: unknown) => ({ content: [{ type: "text" as const, text: JSON.stringify({ suggestions }) }] });
const client = () => createClient(env.ANTHROPIC_API_KEY);

describe("suggestRequest", () => {
  it("asks Sonnet for structured output with the digest as the message", () => {
    const request = suggestRequest(digest());
    expect(request).toMatchObject({ model: "claude-sonnet-5-5", output_config: { effort: "low", format: { type: "json_schema" } } });
    const content = request.messages[0].content as string;
    for (const text of ["Hates coriander.", "id=loved | Fake Miso Salmon | cooked 1 time", "- Fake Coriander Curry, latest rating 1/5"]) {
      expect(content).toContain(text);
    }
    expect(content).not.toContain("id=bad");
  });

  it("keeps the schema to what structured outputs support", () => {
    expect(JSON.stringify(suggestSchema)).not.toMatch(/minimum|maximum|minLength|maxLength|minItems|maxItems/);
  });
});

describe("suggest", () => {
  it("returns the saved recipes the model picked, in its order, with titles and tidy reasons", async () => {
    const claude = mockClaude(reply([
      { recipe_id: "loved", reason: "  You gave this   five stars. " },
      { recipe_id: "new", reason: "Something new." },
    ]));
    const { suggestions } = await suggest(client(), digest());
    expect(claude.requests[0]).toMatchObject({ model: "claude-sonnet-5-5", stream: true });
    expect(suggestions).toEqual([
      { recipe_id: "loved", title: "Fake Miso Salmon", reason: "You gave this five stars." },
      { recipe_id: "new", title: "Fake Pancakes", reason: "Something new." },
    ]);
  });

  it("never returns a recipe rated badly, one the cook doesn't have, or a repeat", async () => {
    mockClaude(reply([
      { recipe_id: "bad", reason: "Spicy!" },
      { recipe_id: "invented", reason: "Trust me." },
      { recipe_id: "loved", reason: "Back again." },
      { recipe_id: "loved", reason: "Again." },
      { recipe_id: "new", reason: "   " },
    ]));
    const { suggestions } = await suggest(client(), digest());
    expect(suggestions.map((s) => s.recipe_id)).toEqual(["loved"]);
  });

  it("drops a badly rated recipe, then offers it again once the cook rates it well", async () => {
    mockClaude(reply([{ recipe_id: "bad", reason: "Worth another go." }]), reply([{ recipe_id: "bad", reason: "Worth another go." }]));
    expect((await suggest(client(), digest())).suggestions).toEqual([]);
    const redeemed = digest([cook("bad", 1), { ...cook("bad", 5), started_at: "2026-11-01T18:00:00Z" }]);
    expect((await suggest(client(), redeemed)).suggestions.map((s) => s.recipe_id)).toEqual(["bad"]);
  });

  it("returns at most five", async () => {
    const recipes = Array.from({ length: 8 }, (_, n) => ({ id: `r${n}`, title: `Fake ${n}` }));
    const many = buildDigest({ today: new Date(), user: { preferences: {}, about: "" }, recipes, cooks: [], topicLinks: [], details: () => ({ ingredients: [], total_minutes: null }) });
    mockClaude(reply(recipes.map((r) => ({ recipe_id: r.id, reason: "Why not." }))));
    expect((await suggest(client(), many)).suggestions).toHaveLength(MAX_SUGGESTIONS);
  });

  it("doesn't call Claude when there is nothing to choose from", async () => {
    const claude = mockClaude();
    const empty = buildDigest({ today: new Date(), user: { preferences: {}, about: "" }, recipes: [], cooks: [], topicLinks: [], details: () => ({ ingredients: [], total_minutes: null }) });
    expect((await suggest(client(), empty)).suggestions).toEqual([]);
    expect(claude.requests).toEqual([]);
  });

  it("gives up on a refusal or output that doesn't fit", async () => {
    mockClaude(
      { content: [{ type: "text", text: "No." }], stop_reason: "refusal" },
      { content: [{ type: "text", text: "not json" }] },
      { content: [{ type: "text", text: JSON.stringify({ suggestions: [{ recipe_id: "loved" }] }) }] },
      { content: [{ type: "text", text: "{" }], stop_reason: "max_tokens" },
    );
    for (let i = 0; i < 4; i++) {
      await expect(suggest(client(), digest())).rejects.toBeInstanceOf(SuggestError);
    }
  });
});
