import type Anthropic from "@anthropic-ai/sdk";
import { describe, expect, it } from "vitest";
import { HttpError } from "./http";
import { appendTurnRequest, owedToolCalls, parseNewSession, parseTurnRequest, requestTurns, sousTurn, sse, toolCallProblem } from "./sessions";

const toolUse = (id: string, name = "show", input: unknown = { view: "step" }) => ({ type: "tool_use" as const, id, name, input });
const toolResult = (id: string, content = "ok") => ({ type: "tool_result" as const, tool_use_id: id, content });

describe("parseNewSession", () => {
  it("takes a recipe id and nothing else", () => {
    expect(parseNewSession({ recipe_id: "r1" })).toEqual({ recipe_id: "r1" });
    for (const bad of [{}, { recipe_id: "" }, { recipe_id: 1 }, { recipe_id: "r1", user_id: "user_x" }, []]) {
      expect(() => parseNewSession(bad)).toThrow(HttpError);
    }
  });
});

describe("parseTurnRequest", () => {
  it("accepts text, tool results or both", () => {
    expect(parseTurnRequest({ text: "hi" })).toEqual({ text: "hi" });
    const results = { tool_results: [{ tool_call_id: "t1", content: "timer-1" }], text: "done" };
    expect(parseTurnRequest(results)).toEqual(results);
  });

  it.each([[{}], [{ text: "" }], [{ tool_results: [] }], [{ text: "hi", extra: 1 }], [{ tool_results: [{ tool_call_id: "t1" }] }]])("rejects %j", (input) => {
    expect(() => parseTurnRequest(input)).toThrow(HttpError);
  });
});

describe("toolCallProblem", () => {
  it("passes calls that match the contract", () => {
    expect(toolCallProblem({ id: "t", name: "start_timer", input: { label: "pasta", seconds: 600 } }, 3)).toBeNull();
    expect(toolCallProblem({ id: "t", name: "go_to_step", input: { index: 2 } }, 3)).toBeNull();
    expect(toolCallProblem({ id: "t", name: "note", input: { fact: "Hates coriander" } }, 3)).toBeNull();
  });

  it("explains what's wrong with a bad call", () => {
    expect(toolCallProblem({ id: "t", name: "start_timer", input: { label: "pasta", seconds: 0 } }, 3)).toMatch(/Invalid start_timer/);
    expect(toolCallProblem({ id: "t", name: "note", input: { fact: "" } }, 3)).toMatch(/Invalid note/);
    expect(toolCallProblem({ id: "t", name: "go_to_step", input: { index: 3 } }, 3)).toMatch(/has 3 steps/);
    expect(toolCallProblem({ id: "t", name: "show", input: "{broken" }, 3)).toMatch(/Invalid show/);
  });
});

describe("owedToolCalls", () => {
  it("lists the last reply's tool calls that have no result yet", () => {
    const messages: Anthropic.MessageParam[] = [
      { role: "user", content: "hi" },
      { role: "assistant", content: [{ type: "text", text: "ok", citations: null }, toolUse("a"), toolUse("b")] },
      { role: "user", content: [toolResult("a", "saved")] },
    ];
    expect(owedToolCalls(messages)).toEqual(["b"]);
    expect(owedToolCalls(messages.slice(0, 1))).toEqual([]);
    expect(owedToolCalls([...messages.slice(0, 2), { role: "user", content: [toolResult("a"), toolResult("b")] }, { role: "assistant", content: "Fine." }])).toEqual([]);
  });
});

describe("appendTurnRequest", () => {
  const owing: Anthropic.MessageParam[] = [
    { role: "user", content: "hi" },
    { role: "assistant", content: [toolUse("note1", "note", { fact: "x" }), toolUse("show1")] },
    { role: "user", content: [toolResult("note1", "saved")] },
  ];

  it("adds a new user message when nothing is owed", () => {
    expect(appendTurnRequest([], { text: "hi" })).toEqual([{ role: "user", content: [{ type: "text", text: "hi" }] }]);
  });

  it("merges the phone's results and text after the brain's results, results first", () => {
    const next = appendTurnRequest(owing, { text: "and now?", tool_results: [{ tool_call_id: "show1", content: "shown", is_error: true }] });
    expect(next.at(-1)).toEqual({
      role: "user",
      content: [toolResult("note1", "saved"), { type: "tool_result", tool_use_id: "show1", content: "shown", is_error: true }, { type: "text", text: "and now?" }],
    });
    expect(next).toHaveLength(3);
    expect(owing[2].content).toHaveLength(1);
  });

  it("insists on a result for every owed call, and only those", () => {
    const owed = (fn: () => unknown) => {
      try {
        fn();
      } catch (e) {
        return e;
      }
    };
    expect(owed(() => appendTurnRequest(owing, { text: "hello?" }))).toMatchObject({ status: 409, code: "tool_results_required", extra: { tool_call_ids: ["show1"] } });
    expect(owed(() => appendTurnRequest(owing, { tool_results: [{ tool_call_id: "other", content: "ok" }] }))).toMatchObject({ status: 409 });
    expect(owed(() => appendTurnRequest([], { tool_results: [{ tool_call_id: "x", content: "ok" }] }))).toMatchObject({ status: 400, code: "unexpected_tool_results" });
  });
});

describe("transcript turns", () => {
  it("records results before what the cook said", () => {
    const results = [{ tool_call_id: "t1", content: "ok" }];
    expect(requestTurns({ text: "next", tool_results: results }, "2026-11-06T18:00:00Z")).toEqual([
      { role: "tool", at: "2026-11-06T18:00:00Z", tool_results: results },
      { role: "cook", at: "2026-11-06T18:00:00Z", text: "next" },
    ]);
  });

  it("skips an empty sous turn", () => {
    expect(sousTurn("", [], "2026-11-06T18:00:00Z")).toBeNull();
    expect(sousTurn("Hi.", [], "2026-11-06T18:00:00Z")).toEqual({ role: "sous", at: "2026-11-06T18:00:00Z", text: "Hi." });
  });
});

describe("sse", () => {
  it("names each event after its type", () => {
    expect(sse({ type: "done", stop_reason: "end_turn" })).toBe('event: done\ndata: {"type":"done","stop_reason":"end_turn"}\n\n');
  });
});
