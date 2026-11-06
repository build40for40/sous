import { env } from "cloudflare:workers";
import Anthropic from "@anthropic-ai/sdk";
import type { Turn } from "@sous/contracts";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createClient } from "./claude";
import { HttpError } from "./http";
import { isRetryable, parseEndRequest, reflect, ReflectionError, reflectionRequest, renderTranscript, type ReflectionInput } from "./reflection";
import { demoRecipe } from "./seed";
import { fakeReflection, mockClaude } from "./testing";

afterEach(() => {
  vi.restoreAllMocks();
});

const turns: Turn[] = [
  { role: "sous", at: "2026-11-06T18:00:00Z", text: "Right then, toastie time." },
  { role: "cook", at: "2026-11-06T18:00:05Z", text: "No cheddar, I've got red leicester." },
  { role: "sous", at: "2026-11-06T18:00:07Z", text: "That works.", tool_calls: [{ id: "toolu_1", name: "note", input: { fact: "Hates coriander" } }] },
  { role: "tool", at: "2026-11-06T18:00:08Z", tool_results: [{ tool_call_id: "toolu_1", content: "saved" }] },
];

const input: ReflectionInput = {
  recipe: { ...demoRecipe, id: "r1", slug: "fake-demo-cheese-toastie", created_at: "2026-11-06T00:00:00Z", updated_at: "2026-11-06T00:00:00Z" },
  user: { preferences: { units: "metric" }, about: "# About me" },
  turns,
  facts: ["Hates coriander"],
  rating: null,
  notes: "Bit pale",
};

describe("parseEndRequest", () => {
  it("accepts nothing, a rating, notes, or nulls", () => {
    expect(parseEndRequest({})).toEqual({});
    expect(parseEndRequest({ rating: 5, notes: "  Lush.  " })).toEqual({ rating: 5, notes: "Lush." });
    expect(parseEndRequest({ rating: null, notes: "   " })).toEqual({});
  });

  it("rejects bad ratings, bad notes and unknown fields", () => {
    for (const body of [[], { rating: 0 }, { rating: 6 }, { rating: 4.5 }, { rating: "5" }, { notes: 3 }, { notes: "x".repeat(4_001) }, { user_id: "someone" }]) {
      expect(() => parseEndRequest(body)).toThrow(HttpError);
    }
  });
});

describe("reflectionRequest", () => {
  it("asks Opus for structured output with everything the reflection reads", () => {
    const request = reflectionRequest(input);
    expect(request).toMatchObject({ model: "claude-opus-5-5", output_config: { effort: "high", format: { type: "json_schema" } } });
    expect(request).not.toHaveProperty("thinking");
    const content = request.messages[0].content as string;
    for (const text of [demoRecipe.title, "# About me", "Cook: No cheddar, I've got red leicester.", "- Hates coriander", "Not given.", "Bit pale"]) {
      expect(content).toContain(text);
    }
    expect(content).not.toContain(`"slug"`);
  });

  it("keeps the schema to what structured outputs support", () => {
    const schema = JSON.stringify(reflectionRequest(input).output_config!.format!.schema);
    expect(schema).not.toMatch(/minimum|maximum|minLength|maxLength|minItems|maxItems/);
  });
});

describe("renderTranscript", () => {
  it("writes the cook and Sous line by line, with Sous's tool calls and without tool results", () => {
    expect(renderTranscript(turns)).toBe(
      ["Sous: Right then, toastie time.", "Cook: No cheddar, I've got red leicester.", "Sous: That works.", '(Sous used note {"fact":"Hates coriander"})'].join("\n"),
    );
  });
});

describe("reflect", () => {
  const client = () => createClient(env.ANTHROPIC_API_KEY);

  it("tidies the model's output, and the cook's own rating wins", async () => {
    const claude = mockClaude({ content: [{ type: "text", text: JSON.stringify(fakeReflection) }] });
    const { reflection } = await reflect(client(), { ...input, rating: 5 });
    expect(claude.requests[0]).toMatchObject({ model: "claude-opus-5-5", stream: true });
    expect(reflection).toEqual({
      rating: 5,
      summary: "Golden toastie, cheese a touch underdone.",
      worked: ["Buttering edge to edge"],
      failed: ["Lower the heat so the cheese melts first"],
      substitutions: [{ original: "cheddar", replacement: "red leicester", outcome: "Melted well" }],
      preferences: ["Hates coriander"],
      ingredients: ["bread", "red leicester"],
      techniques: ["toasting"],
      cuisine: "british",
    });
  });

  it("keeps the model's rating when the cook gave none", async () => {
    mockClaude({ content: [{ type: "text", text: JSON.stringify(fakeReflection) }] });
    expect((await reflect(client(), input)).reflection.rating).toBe(3);
  });

  it("gives up for good on a refusal or output that doesn't fit", async () => {
    mockClaude(
      { content: [{ type: "text", text: "No." }], stop_reason: "refusal" },
      { content: [{ type: "text", text: "not json" }] },
      { content: [{ type: "text", text: JSON.stringify({ ...fakeReflection, rating: 9 }) }] },
      { content: [{ type: "text", text: "{" }], stop_reason: "max_tokens" },
    );
    for (let i = 0; i < 4; i++) {
      const failure = await reflect(client(), input).catch((e) => e);
      expect(failure).toBeInstanceOf(ReflectionError);
      expect(isRetryable(failure)).toBe(false);
    }
  });
});

describe("isRetryable", () => {
  it("retries rate limits, overloads and network trouble, not bad requests", () => {
    const apiError = (status: number) => Anthropic.APIError.generate(status, { type: "error", error: { type: "x", message: "x" } }, "x", new Headers());
    expect(isRetryable(apiError(429))).toBe(true);
    expect(isRetryable(apiError(529))).toBe(true);
    expect(isRetryable(apiError(500))).toBe(true);
    expect(isRetryable(apiError(400))).toBe(false);
    expect(isRetryable(apiError(401))).toBe(false);
    expect(isRetryable(new TypeError("fetch failed"))).toBe(true);
  });
});
