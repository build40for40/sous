import Anthropic from "@anthropic-ai/sdk";
import { tools } from "@sous/contracts";
import { STAGE_PROMPT } from "./prompt";

export const DEFAULT_LIVE_MODEL = "claude-sonnet-5-5";
export const MAX_TOKENS = 16_000;

export function liveModel(env: Pick<Env, "SOUS_LIVE_MODEL">): string {
  return env.SOUS_LIVE_MODEL?.trim() || DEFAULT_LIVE_MODEL;
}

export function createClient(apiKey: string): Anthropic {
  return new Anthropic({
    apiKey,
    maxRetries: 1,
    timeout: 60_000,
    fetch: (input, init) => fetch(input, init),
  });
}

/** Thinking off where the model allows it, for the fastest spoken reply. */
export function thinkingFor(model: string): Anthropic.ThinkingConfigParam | undefined {
  if (model.startsWith("claude-sonnet-5-5")) return { type: "between_tools" };
  if (model.startsWith("claude-haiku-5-5")) return { type: "disabled" };
  return undefined;
}

export function systemBlocks(context: string): Anthropic.TextBlockParam[] {
  return [
    { type: "text", text: STAGE_PROMPT },
    { type: "text", text: context, cache_control: { type: "ephemeral" } },
  ];
}

export function liveRequest(model: string, context: string, messages: Anthropic.MessageParam[]): Anthropic.MessageCreateParamsNonStreaming {
  const thinking = thinkingFor(model);
  return {
    model,
    max_tokens: MAX_TOKENS,
    system: systemBlocks(context),
    tools: tools as unknown as Anthropic.Tool[],
    messages,
    cache_control: { type: "ephemeral" },
    output_config: { effort: "low" },
    ...(thinking ? { thinking } : {}),
  };
}
