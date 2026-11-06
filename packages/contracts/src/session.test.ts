import Ajv2020, { type ValidateFunction } from "ajv/dist/2020";
import addFormats from "ajv-formats";
import { describe, expect, it } from "vitest";
import recipeExample from "../examples/recipe.json";
import example from "../examples/session.json";
import { type Session, type StreamEvent, sessionSchema, stages, type TurnRequest } from "./session";

const ajv = new Ajv2020({ strict: true, strictRequired: false, allErrors: true });
addFormats(ajv);
ajv.addSchema(sessionSchema);

function validator(def?: string): ValidateFunction {
  const ref = def ? `${sessionSchema.$id}#/$defs/${def}` : sessionSchema.$id;
  const validate = ajv.getSchema(ref);
  if (!validate) throw new Error(`No schema at ${ref}`);
  return validate;
}

const validateSession = validator();
const validateTurnRequest = validator("TurnRequest");
const validateStreamEvent = validator("StreamEvent");

function broken(change: (session: any) => void): unknown {
  const session = structuredClone(example);
  change(session);
  return session;
}

describe("session schema", () => {
  it("accepts the example session", () => {
    expect(validateSession(example), JSON.stringify(validateSession.errors)).toBe(true);
  });

  it("points the example session at the example recipe", () => {
    expect(example.recipe_id).toBe(recipeExample.id);
  });

  it("answers every tool call in the example with a result in the next turn", () => {
    const turns = example.turns as Session["turns"];
    turns.forEach((turn, i) => {
      if (turn.role !== "sous" || !turn.tool_calls) return;
      const next = turns[i + 1];
      expect(next?.role).toBe("tool");
      const answered = next?.role === "tool" ? next.tool_results.map((r) => r.tool_call_id) : [];
      expect(answered).toEqual(turn.tool_calls.map((c) => c.id));
    });
  });

  it("lists the stages in the same order as the TypeScript constant", () => {
    expect(sessionSchema.$defs.Stage.enum).toEqual([...stages]);
  });

  it.each<[string, (session: any) => void]>([
    ["an unknown stage", (s) => (s.stage = "washing-up")],
    ["no turns", (s) => delete s.turns],
    ["a turn with an unknown role", (s) => (s.turns[0].role = "chef")],
    ["a cook turn without text", (s) => delete s.turns[0].text],
    ["a cook turn with tool calls", (s) => (s.turns[0].tool_calls = s.turns[1].tool_calls)],
    ["a sous turn with neither text nor tool calls", (s) => (s.turns[1] = { role: "sous", at: s.turns[1].at })],
    ["a tool turn without results", (s) => (s.turns[2].tool_results = [])],
    ["a call to an unknown tool", (s) => (s.turns[1].tool_calls[0].name = "order_pizza")],
    ["an await_ack call with an empty short form", (s) => (s.turns[7].tool_calls[0] = { id: "toolu_fake_20", name: "await_ack", input: { short: "" } })],
    ["a timer of zero seconds", (s) => (s.turns[4].tool_calls[2].input.seconds = 0)],
    ["a negative step index", (s) => (s.turns[4].tool_calls[1].input.index = -1)],
    ["set_stage to an unknown stage", (s) => (s.turns[1].tool_calls[0].input.stage = "nap")],
    ["show with an unknown view", (s) => (s.turns[1].tool_calls[1].input.view = "video")],
    ["a tool input with an extra field", (s) => (s.turns[1].tool_calls[1].input.zoom = 2)],
    ["a tool result without content", (s) => delete s.turns[2].tool_results[0].content],
    ["a rating of six", (s) => (s.rating = 6)],
    ["a bad timestamp", (s) => (s.started_at = "six o'clock")],
  ])("rejects a session with %s", (_, change) => {
    expect(validateSession(broken(change))).toBe(false);
  });
});

describe("turn request", () => {
  it.each<[string, TurnRequest]>([
    ["text", { text: "Is the sofrito meant to be this dark?" }],
    ["tool results", { tool_results: [{ tool_call_id: "toolu_fake_05", content: "timer-1" }] }],
    [
      "both",
      {
        text: "Timer's going.",
        tool_results: [{ tool_call_id: "toolu_fake_05", content: "timer-2", is_error: false }],
      },
    ],
    ["a finished timer on its own, when the chef only tapped the flame", { events: [{ type: "timer_finished", timer_id: "timer-1", label: "rice" }] }],
    [
      "a finished timer with what the chef said",
      { text: "What's up?", events: [{ type: "timer_finished", timer_id: "timer-1", label: "rice" }, { type: "timer_finished", timer_id: "timer-2", label: "dahl" }] },
    ],
  ])("accepts %s", (_, body) => {
    expect(validateTurnRequest(body), JSON.stringify(validateTurnRequest.errors)).toBe(true);
  });

  it.each<[string, unknown]>([
    ["an empty body", {}],
    ["empty text", { text: "" }],
    ["an empty results list", { tool_results: [] }],
    ["a user id", { text: "hi", user_id: "someone-else" }],
    ["an empty events list", { events: [] }],
    ["an unknown phone event", { events: [{ type: "oven_preheated" }] }],
    ["a finished timer without its label", { events: [{ type: "timer_finished", timer_id: "timer-1" }] }],
    ["a finished timer with an empty id", { events: [{ type: "timer_finished", timer_id: "", label: "rice" }] }],
    ["a finished timer with an extra field", { events: [{ type: "timer_finished", timer_id: "timer-1", label: "rice", seconds: 600 }] }],
    ["more than ten events", { events: Array.from({ length: 11 }, (_, i) => ({ type: "timer_finished", timer_id: `timer-${i}`, label: "rice" })) }],
  ])("rejects %s", (_, body) => {
    expect(validateTurnRequest(body)).toBe(false);
  });
});

describe("stream events", () => {
  const events: StreamEvent[] = [
    { type: "text", delta: "Two table" },
    { type: "text", delta: "spoons of oil." },
    { type: "tool_call", tool_call: { id: "toolu_fake_10", name: "start_timer", input: { label: "onions", seconds: 600 } } },
    { type: "tool_call", tool_call: { id: "toolu_fake_11", name: "show", input: { view: "done_cue" } } },
    { type: "done", stop_reason: "tool_use" },
    { type: "done", stop_reason: "end_turn" },
    { type: "done", stop_reason: "end_turn", awaiting_ack: { short: "Chef, rice, twelve minutes. Heard?" } },
    { type: "error", message: "Sous lost the thread. Try again." },
  ];

  it.each(events.map((event) => [event.type, event] as const))("accepts a %s event", (_, event) => {
    expect(validateStreamEvent(event), JSON.stringify(validateStreamEvent.errors)).toBe(true);
  });

  it.each<[string, unknown]>([
    ["an unknown event type", { type: "thinking", delta: "hmm" }],
    ["a text event without a delta", { type: "text" }],
    ["a note call, which the brain runs itself", { type: "tool_call", tool_call: { id: "toolu_fake_12", name: "note", input: { fact: "Hates coriander" } } }],
    ["an unknown stop reason", { type: "done", stop_reason: "max_tokens" }],
    ["awaiting_ack without a short form", { type: "done", stop_reason: "end_turn", awaiting_ack: {} }],
    ["awaiting_ack with an empty short form", { type: "done", stop_reason: "end_turn", awaiting_ack: { short: "" } }],
    ["awaiting_ack as a bare string", { type: "done", stop_reason: "end_turn", awaiting_ack: "Chef, rice. Heard?" }],
    ["an await_ack call, which the brain runs itself", { type: "tool_call", tool_call: { id: "toolu_fake_13", name: "await_ack", input: { short: "Chef, rice. Heard?" } } }],
    ["an error without a message", { type: "error" }],
  ])("rejects %s", (_, event) => {
    expect(validateStreamEvent(event)).toBe(false);
  });
});
