import Ajv2020 from "ajv/dist/2020";
import { describe, expect, it } from "vitest";
import sessionExample from "../examples/session.json";
import { sessionSchema, stages } from "./session";
import { clientToolNames, serverToolNames, tools } from "./tools";

const ajv = new Ajv2020({ strict: true, allErrors: true });

const callDefs: Record<string, string> = {
  start_timer: "StartTimerCall",
  cancel_timer: "CancelTimerCall",
  go_to_step: "GoToStepCall",
  set_stage: "SetStageCall",
  show: "ShowCall",
  note: "NoteCall",
  await_ack: "AwaitAckCall",
};

const unsupportedInStrictMode = ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf", "minLength", "maxLength"];

function keysDeep(value: unknown): string[] {
  if (!value || typeof value !== "object") return [];
  return Object.entries(value).flatMap(([key, child]) => [key, ...keysDeep(child)]);
}

describe("tool definitions", () => {
  it("defines exactly the client and server tools, once each", () => {
    expect(tools.map((t) => t.name).sort()).toEqual([...clientToolNames, ...serverToolNames].sort());
  });

  it.each(tools.map((tool) => [tool.name, tool] as const))("%s is a valid Claude Messages API custom tool", (_, tool) => {
    expect(Object.keys(tool).sort()).toEqual(["description", "input_schema", "name", "strict"]);
    expect(tool.name).toMatch(/^[a-zA-Z0-9_-]{1,64}$/);
    expect(tool.description.length).toBeGreaterThan(20);
    expect(tool.strict).toBe(true);
    expect(tool.input_schema.type).toBe("object");
    expect(tool.input_schema.additionalProperties).toBe(false);
    expect([...tool.input_schema.required].sort()).toEqual(Object.keys(tool.input_schema.properties).sort());
    expect(keysDeep(tool.input_schema).filter((k) => unsupportedInStrictMode.includes(k))).toEqual([]);
    expect(() => ajv.compile(tool.input_schema)).not.toThrow();
  });

  it.each(tools.map((tool) => [tool.name, tool] as const))("%s takes the same input the session schema records", (_, tool) => {
    const recorded = (sessionSchema.$defs as Record<string, any>)[callDefs[tool.name]].properties.input;
    expect([...recorded.required].sort()).toEqual([...tool.input_schema.required].sort());
    for (const [key, property] of Object.entries(tool.input_schema.properties) as [string, any][]) {
      const recordedProperty = recorded.properties[key].$ref
        ? (sessionSchema.$defs as Record<string, any>)[recorded.properties[key].$ref.split("/").pop()]
        : recorded.properties[key];
      if (property.enum) expect(recordedProperty.enum).toEqual(property.enum);
      else expect(recordedProperty.type).toBe(property.type);
    }
  });

  it("offers set_stage every stage", () => {
    const setStage = tools.find((t) => t.name === "set_stage")!;
    expect((setStage.input_schema.properties.stage as { enum: string[] }).enum).toEqual([...stages]);
  });

  it("runs note and await_ack in the brain and everything else on the phone", () => {
    expect([...serverToolNames]).toEqual(["note", "await_ack"]);
    expect([...clientToolNames]).not.toContain("await_ack");
  });

  it("asks for a short form of the instruction in await_ack", () => {
    const awaitAck = tools.find((t) => t.name === "await_ack")!;
    expect(awaitAck.input_schema.required).toEqual(["short"]);
    expect((awaitAck.input_schema.properties.short as { description: string }).description).toContain("Chef, rice, twelve minutes. Heard?");
  });

  it("accepts every tool call in the example session", () => {
    const turns = sessionExample.turns as { tool_calls?: { name: string; input: unknown }[] }[];
    const calls = turns.flatMap((turn) => turn.tool_calls ?? []);
    expect(calls.length).toBeGreaterThan(0);
    for (const call of calls) {
      const tool = tools.find((t) => t.name === call.name);
      expect(tool, call.name).toBeDefined();
      const validate = ajv.compile(tool!.input_schema);
      expect(validate(call.input), JSON.stringify(validate.errors)).toBe(true);
    }
  });
});
