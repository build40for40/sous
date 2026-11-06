import { env } from "cloudflare:workers";
import type { StreamEvent } from "@sous/contracts";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createClient } from "./claude";
import { mockClaude } from "./testing";
import { MAX_ROUNDS, runTurn, TurnError } from "./turn";

afterEach(() => {
  vi.restoreAllMocks();
});

function run(...replies: Parameters<typeof mockClaude>) {
  const claude = mockClaude(...replies);
  const events: StreamEvent[] = [];
  const outcome = runTurn({
    client: createClient(env.ANTHROPIC_API_KEY),
    model: "claude-sonnet-5-5",
    context: "context",
    messages: [{ role: "user", content: [{ type: "text", text: "Go on then." }] }],
    stepCount: 3,
    emit: (e) => events.push(e),
    now: () => "2026-11-06T18:00:00Z",
  });
  return { claude, events, outcome };
}

describe("runTurn", () => {
  it("streams text as it arrives and returns the reply for the history", async () => {
    const { events, outcome } = run({ content: [{ type: "text", text: "Butter the bread." }] });
    const result = await outcome;
    expect(events).toEqual([
      { type: "text", delta: "Butter th" },
      { type: "text", delta: "e bread." },
    ]);
    expect(result.stopReason).toBe("end_turn");
    expect(result.messages.at(-1)).toMatchObject({ role: "assistant", content: [{ type: "text", text: "Butter the bread." }] });
    expect(result.turns).toEqual([{ role: "sous", at: "2026-11-06T18:00:00Z", text: "Butter the bread." }]);
    expect(result.timings.first_text_ms).toEqual(expect.any(Number));
    expect(result.usage).toHaveLength(1);
  });

  it("puts a space between separate text blocks", async () => {
    const { events, outcome } = run({
      content: [
        { type: "text", text: "Right." },
        { type: "tool_use", name: "show", input: { view: "step" } },
        { type: "text", text: "There it is." },
      ],
    });
    const result = await outcome;
    expect(events.flatMap((e) => (e.type === "text" ? [e.delta] : [])).join("")).toBe("Right. There it is.");
    expect(result.turns[0]).toMatchObject({ text: "Right. There it is." });
  });

  it("never sends the phone a bad tool call, and tells Claude what was wrong instead", async () => {
    const { claude, events, outcome } = run(
      {
        content: [
          { type: "tool_use", id: "bad_timer", name: "start_timer", input: { label: "toast", seconds: 0 } },
          { type: "tool_use", id: "bad_step", name: "go_to_step", input: { index: 7 } },
          { type: "tool_use", id: "made_up", name: "open_oven", input: {} },
        ],
      },
      { content: [{ type: "tool_use", id: "good_timer", name: "start_timer", input: { label: "toast", seconds: 180 } }] },
    );
    const result = await outcome;
    expect(events.filter((e) => e.type === "tool_call")).toEqual([{ type: "tool_call", tool_call: { id: "good_timer", name: "start_timer", input: { label: "toast", seconds: 180 } } }]);
    expect(claude.requests[1].messages.at(-1).content).toEqual([
      expect.objectContaining({ tool_use_id: "bad_timer", is_error: true }),
      expect.objectContaining({ tool_use_id: "bad_step", is_error: true, content: expect.stringContaining("3 steps") }),
      expect.objectContaining({ tool_use_id: "made_up", is_error: true }),
    ]);
    expect(result.stopReason).toBe("tool_use");
  });

  it("tracks the stage the cook moved to", async () => {
    const { outcome } = run({ content: [{ type: "tool_use", name: "set_stage", input: { stage: "present" } }] });
    expect((await outcome).stage).toBe("present");
  });

  it("gives up if Claude keeps calling server tools", async () => {
    const notes = Array.from({ length: MAX_ROUNDS }, () => ({ content: [{ type: "tool_use" as const, name: "note", input: { fact: "Again" } }] }));
    const { outcome } = run(...notes);
    await expect(outcome).rejects.toThrow(TurnError);
  });

  it("fails on a reply cut off at max_tokens", async () => {
    const { outcome } = run({ content: [{ type: "text", text: "And then" }], stop_reason: "max_tokens" });
    await expect(outcome).rejects.toThrow(TurnError);
  });
});
