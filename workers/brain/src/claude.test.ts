import { tools } from "@sous/contracts";
import { describe, expect, it } from "vitest";
import { DEFAULT_LIVE_MODEL, liveModel, liveRequest, thinkingFor } from "./claude";
import { STAGE_PROMPT } from "./prompt";

describe("liveModel", () => {
  it("defaults to Sonnet and can drop to Haiku", () => {
    expect(DEFAULT_LIVE_MODEL).toBe("claude-sonnet-5-5");
    expect(liveModel({ SOUS_LIVE_MODEL: "" as never })).toBe("claude-sonnet-5-5");
    expect(liveModel({ SOUS_LIVE_MODEL: "claude-haiku-5-5" as never })).toBe("claude-haiku-5-5");
  });
});

describe("thinkingFor", () => {
  it("turns thinking off in the way each live model accepts", () => {
    expect(thinkingFor("claude-sonnet-5-5")).toEqual({ type: "between_tools" });
    expect(thinkingFor("claude-haiku-5-5")).toEqual({ type: "disabled" });
    expect(thinkingFor("claude-opus-5-5")).toBeUndefined();
  });
});

describe("liveRequest", () => {
  const messages = [{ role: "user" as const, content: "Hi" }];

  it("caches the tools, stage prompt and context, and the conversation so far", () => {
    const request = liveRequest("claude-sonnet-5-5", "the context", messages);
    expect(request.tools).toEqual(tools);
    expect(request.system).toEqual([
      { type: "text", text: STAGE_PROMPT },
      { type: "text", text: "the context", cache_control: { type: "ephemeral" } },
    ]);
    expect(request.cache_control).toEqual({ type: "ephemeral" });
    expect(request.messages).toBe(messages);
  });

  it("asks for a quick reply", () => {
    expect(liveRequest("claude-sonnet-5-5", "c", messages)).toMatchObject({ model: "claude-sonnet-5-5", thinking: { type: "between_tools" }, output_config: { effort: "low" } });
    expect(liveRequest("claude-haiku-5-5", "c", messages)).toMatchObject({ model: "claude-haiku-5-5", thinking: { type: "disabled" } });
    expect(liveRequest("claude-opus-5-5", "c", messages)).not.toHaveProperty("thinking");
  });
});
