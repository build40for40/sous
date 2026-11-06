import toolsJson from "../tools.json";
import type { Stage } from "./session";

export const clientToolNames = ["start_timer", "cancel_timer", "go_to_step", "set_stage", "show"] as const;
export const serverToolNames = ["note", "await_ack"] as const;

export type ClientToolName = (typeof clientToolNames)[number];
export type ServerToolName = (typeof serverToolNames)[number];
export type ToolName = ClientToolName | ServerToolName;

export type ShowView = "step" | "ingredients" | "done_cue";

export interface ToolInputs {
  start_timer: { label: string; seconds: number };
  cancel_timer: { timer_id: string };
  go_to_step: { index: number };
  set_stage: { stage: Stage };
  show: { view: ShowView };
  note: { fact: string };
  await_ack: { short: string };
}

export interface ToolDefinition {
  name: ToolName;
  description: string;
  strict: true;
  input_schema: {
    type: "object";
    additionalProperties: false;
    required: string[];
    properties: Record<string, unknown>;
  };
}

export const tools = toolsJson as ToolDefinition[];
