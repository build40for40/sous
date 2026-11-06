import type Anthropic from "@anthropic-ai/sdk";
import { Validator, type Schema } from "@cfworker/json-schema";
import { clientToolNames, sessionSchema, type ClientToolName, type Stage, type StreamEvent, type ToolCall, type Turn, type TurnRequest } from "@sous/contracts";
import { HttpError, isPlainObject } from "./http";

export interface SessionRow extends Record<string, SqlStorageValue> {
  id: string;
  recipe_id: string;
  stage: string;
  model: string;
  context: string;
  messages: string;
  turns: string;
  facts: string;
  started_at: string;
  ended_at: string | null;
}

export interface NewSession {
  id: string;
  recipe_id: string;
  stage: Stage;
  started_at: string;
  opening_line: string;
}

const defs = (sessionSchema as { $defs: Record<string, unknown> }).$defs;
const validatorFor = (def: string) => new Validator({ $defs: defs, $ref: `#/$defs/${def}` } as unknown as Schema, "2020-12", false);
const turnRequestValidator = validatorFor("TurnRequest");
const toolCallValidator = validatorFor("ToolCall");

export function parseNewSession(input: unknown): { recipe_id: string } {
  if (!isPlainObject(input) || typeof input.recipe_id !== "string" || !input.recipe_id || Object.keys(input).length !== 1) {
    throw new HttpError(400, "invalid_session", { message: "Send {recipe_id}." });
  }
  return { recipe_id: input.recipe_id };
}

export function parseTurnRequest(input: unknown): TurnRequest {
  const result = turnRequestValidator.validate(input);
  if (!result.valid) {
    const issues = result.errors
      .filter((e) => !["$ref", "properties", "items", "anyOf"].includes(e.keyword))
      .slice(0, 10)
      .map((e) => ({ path: e.instanceLocation, message: e.error }));
    throw new HttpError(400, "invalid_turn", { issues });
  }
  return input as TurnRequest;
}

export const isClientTool = (name: string): name is ClientToolName => (clientToolNames as readonly string[]).includes(name);

/** Why a tool call can't run, or null when it can. */
export function toolCallProblem(call: { id: string; name: string; input: unknown }, stepCount: number): string | null {
  const result = toolCallValidator.validate(call);
  if (!result.valid) return `Invalid ${call.name} input: ${JSON.stringify(call.input)}.`;
  if (call.name === "go_to_step" && (call.input as { index: number }).index >= stepCount) {
    return `There's no step ${(call.input as { index: number }).index}: the recipe has ${stepCount} steps, numbered from zero.`;
  }
  return null;
}

/** Tool calls in the last reply that still need a result. */
export function owedToolCalls(messages: Anthropic.MessageParam[]): string[] {
  const last = messages.findLastIndex((m) => m.role === "assistant");
  if (last === -1) return [];
  const asked = blocks(messages[last]).flatMap((b) => (b.type === "tool_use" ? [b.id] : []));
  const answered = new Set(messages.slice(last + 1).flatMap((m) => blocks(m).flatMap((b) => (b.type === "tool_result" ? [b.tool_use_id] : []))));
  return asked.filter((id) => !answered.has(id));
}

/** Checks the request answers exactly the owed calls, then adds it to the history as the cook's message. */
export function appendTurnRequest(messages: Anthropic.MessageParam[], request: TurnRequest): Anthropic.MessageParam[] {
  const owed = owedToolCalls(messages);
  const sent = (request.tool_results ?? []).map((r) => r.tool_call_id);
  if (owed.length && (sent.length !== owed.length || !owed.every((id) => sent.includes(id)))) {
    throw new HttpError(409, "tool_results_required", { tool_call_ids: owed });
  }
  if (!owed.length && sent.length) throw new HttpError(400, "unexpected_tool_results");

  const content: Anthropic.ContentBlockParam[] = [
    ...(request.tool_results ?? []).map(
      (r): Anthropic.ToolResultBlockParam => ({ type: "tool_result", tool_use_id: r.tool_call_id, content: r.content, ...(r.is_error ? { is_error: true } : {}) }),
    ),
    ...(request.text ? [{ type: "text" as const, text: request.text }] : []),
  ];
  const last = messages.at(-1);
  if (last?.role === "user") return [...messages.slice(0, -1), { role: "user", content: [...blocks(last), ...content] }];
  return [...messages, { role: "user", content }];
}

export function requestTurns(request: TurnRequest, at: string): Turn[] {
  const turns: Turn[] = [];
  if (request.tool_results?.length) turns.push({ role: "tool", at, tool_results: request.tool_results });
  if (request.text) turns.push({ role: "cook", at, text: request.text });
  return turns;
}

export function sousTurn(text: string, toolCalls: ToolCall[], at: string): Turn | null {
  if (!text && !toolCalls.length) return null;
  return { role: "sous", at, ...(text ? { text } : {}), ...(toolCalls.length ? { tool_calls: toolCalls } : {}) } as Turn;
}

export function sse(event: StreamEvent): string {
  return `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`;
}

function blocks(message: Anthropic.MessageParam): Anthropic.ContentBlockParam[] {
  return typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content;
}
