import sessionSchema from "../schemas/session.schema.json";
import type { ClientToolName, ToolInputs, ToolName } from "./tools";

export { sessionSchema };

export const stages = ["decide", "prep", "cook", "present", "feedback"] as const;
export type Stage = (typeof stages)[number];

export interface Session {
  id: string;
  recipe_id: string;
  stage: Stage;
  started_at: string;
  ended_at?: string;
  turns: Turn[];
  facts?: string[];
  rating?: 1 | 2 | 3 | 4 | 5;
  notes?: string;
}

export type Turn = CookTurn | SousTurn | ToolTurn;

export interface CookTurn {
  role: "cook";
  at: string;
  text: string;
}

export type SousTurn = {
  role: "sous";
  at: string;
} & ({ text: string; tool_calls?: ToolCall[] } | { text?: string; tool_calls: ToolCall[] });

export interface ToolTurn {
  role: "tool";
  at: string;
  tool_results: ToolResult[];
}

export type ToolCall<N extends ToolName = ToolName> = {
  [K in N]: { id: string; name: K; input: ToolInputs[K] };
}[N];

export interface ToolResult {
  tool_call_id: string;
  content: string;
  is_error?: boolean;
}

export type TurnRequest = { text?: string; tool_results?: ToolResult[]; events?: PhoneEvent[] } & (
  | { text: string }
  | { tool_results: ToolResult[] }
  | { events: PhoneEvent[] }
);

export type PhoneEvent = TimerFinishedEvent;

export interface TimerFinishedEvent {
  type: "timer_finished";
  timer_id: string;
  label: string;
}

export type StreamEvent = TextEvent | ToolCallEvent | DoneEvent | ErrorEvent;

export interface TextEvent {
  type: "text";
  delta: string;
}

export interface ToolCallEvent {
  type: "tool_call";
  tool_call: ToolCall<ClientToolName>;
}

export interface DoneEvent {
  type: "done";
  stop_reason: "end_turn" | "tool_use";
  awaiting_ack?: AwaitingAck;
}

export interface AwaitingAck {
  short: string;
}

export interface ErrorEvent {
  type: "error";
  message: string;
}
