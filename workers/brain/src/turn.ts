import type Anthropic from "@anthropic-ai/sdk";
import type { ClientToolName, Stage, StreamEvent, ToolCall, ToolResult, Turn } from "@sous/contracts";
import { liveRequest } from "./claude";
import { isClientTool, sousTurn, toolCallProblem } from "./sessions";

export const MAX_ROUNDS = 4;

export interface TurnInput {
  client: Anthropic;
  model: string;
  context: string;
  /** The history, ending with the cook's new message. */
  messages: Anthropic.MessageParam[];
  stepCount: number;
  emit: (event: StreamEvent) => void;
  now?: () => string;
}

export interface TurnOutcome {
  messages: Anthropic.MessageParam[];
  turns: Turn[];
  facts: string[];
  stage: Stage | null;
  stopReason: "end_turn" | "tool_use";
  timings: { first_text_ms: number | null; total_ms: number };
  usage: Pick<Anthropic.Usage, "input_tokens" | "output_tokens" | "cache_read_input_tokens" | "cache_creation_input_tokens">[];
}

export class TurnError extends Error {}

interface PendingToolUse {
  id: string;
  name: string;
  json: string;
}

/** Runs one cook turn: streams Claude's reply, runs note itself and hands client tools to the phone. */
export async function runTurn({ client, model, context, messages: history, stepCount, emit, now = () => new Date().toISOString() }: TurnInput): Promise<TurnOutcome> {
  const started = Date.now();
  let firstText: number | null = null;
  const messages = [...history];
  const turns: Turn[] = [];
  const facts: string[] = [];
  const usage: TurnOutcome["usage"] = [];
  let stage: Stage | null = null;
  let spoke = false;

  for (let round = 0; round < MAX_ROUNDS; round++) {
    const stream = client.messages.stream(liveRequest(model, context, messages));
    const pending = new Map<number, PendingToolUse>();
    const recorded: ToolCall[] = [];
    const serverResults: ToolResult[] = [];
    const ackIds = new Set<string>();
    let clientCalls = 0;

    for await (const event of stream) {
      if (event.type === "content_block_start") {
        if (event.content_block.type === "text" && spoke) emit({ type: "text", delta: " " });
        if (event.content_block.type === "tool_use") pending.set(event.index, { id: event.content_block.id, name: event.content_block.name, json: "" });
      } else if (event.type === "content_block_delta") {
        if (event.delta.type === "text_delta" && event.delta.text) {
          firstText ??= Date.now() - started;
          spoke = true;
          emit({ type: "text", delta: event.delta.text });
        } else if (event.delta.type === "input_json_delta") {
          const call = pending.get(event.index);
          if (call) call.json += event.delta.partial_json;
        }
      } else if (event.type === "content_block_stop") {
        const block = pending.get(event.index);
        if (!block) continue;
        const call = { id: block.id, name: block.name, input: parseInput(block.json) };
        const problem = toolCallProblem(call, stepCount);
        if (problem) {
          serverResults.push({ tool_call_id: call.id, content: problem, is_error: true });
        } else if (call.name === "await_ack") {
          ackIds.add(call.id);
          serverResults.push({ tool_call_id: call.id, content: "Waiting for the chef." });
        } else if (call.name === "note") {
          const fact = (call.input as { fact: string }).fact.trim();
          facts.push(fact);
          recorded.push(call as ToolCall);
          serverResults.push({ tool_call_id: call.id, content: "saved" });
        } else if (isClientTool(call.name)) {
          if (call.name === "set_stage") stage = (call.input as { stage: Stage }).stage;
          recorded.push(call as ToolCall);
          clientCalls++;
          emit({ type: "tool_call", tool_call: call as ToolCall<ClientToolName> });
        } else {
          serverResults.push({ tool_call_id: call.id, content: `There's no tool called ${call.name}.`, is_error: true });
        }
      }
    }

    const message = await stream.finalMessage();
    usage.push(message.usage);
    if (message.stop_reason === "refusal") throw new TurnError("Claude declined to reply.");
    if (message.stop_reason === "max_tokens") throw new TurnError("The reply ran out of room.");

    const text = message.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join(" ");
    const timings = () => ({ first_text_ms: firstText, total_ms: Date.now() - started });
    // The API rejects an empty assistant message, so a silent reply leaves the chef's message open for the next turn to join.
    if (!text.trim() && !pending.size) return { messages, turns, facts, stage, stopReason: "end_turn", timings: timings(), usage };

    messages.push({ role: "assistant", content: message.content as Anthropic.ContentBlockParam[] });
    const reply = sousTurn(text, recorded, now());
    if (reply) turns.push(reply);

    if (message.stop_reason !== "tool_use" || (!clientCalls && !serverResults.length)) {
      return { messages, turns, facts, stage, stopReason: "end_turn", timings: timings(), usage };
    }
    if (serverResults.length) {
      messages.push({
        role: "user",
        content: serverResults.map((r) => ({ type: "tool_result", tool_use_id: r.tool_call_id, content: r.content, ...(r.is_error ? { is_error: true } : {}) })),
      });
      const shown = serverResults.filter((r) => !ackIds.has(r.tool_call_id));
      if (shown.length) turns.push({ role: "tool", at: now(), tool_results: shown });
    }
    if (clientCalls) return { messages, turns, facts, stage, stopReason: "tool_use", timings: timings(), usage };
    if (ackIds.size && !serverResults.some((r) => r.is_error)) return { messages, turns, facts, stage, stopReason: "end_turn", timings: timings(), usage };
  }
  throw new TurnError(`Still calling tools after ${MAX_ROUNDS} rounds.`);
}

function parseInput(json: string): unknown {
  try {
    return json ? JSON.parse(json) : {};
  } catch {
    return json;
  }
}
