import { env } from "cloudflare:workers";
import { exportJWK, generateKeyPair, SignJWT } from "jose";
import { vi } from "vitest";
import { workosIssuer, workosJwksUrl } from "./workos";

/** Test doubles for everything outside the Worker: WorkOS, Claude, Instagram and recipe sites. Nothing real is ever fetched. */

const KID = "test-key";
const keyPair = generateKeyPair("RS256", { extractable: true });
const jwks = keyPair.then(async ({ publicKey }) => ({ keys: [{ ...(await exportJWK(publicKey)), kid: KID, alg: "RS256", use: "sig" }] }));

export async function signToken(sub = "user_alice"): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({})
    .setProtectedHeader({ alg: "RS256", kid: KID })
    .setSubject(sub)
    .setIssuer(workosIssuer(env.WORKOS_CLIENT_ID))
    .setIssuedAt(now - 60)
    .setExpirationTime(now + 300)
    .sign((await keyPair).privateKey);
}

export interface Web {
  /** URL → page body, or a status number to fail with. */
  pages: Map<string, string | number>;
  /** Every outbound request: [url, user agent]. */
  requests: [string, string | null][];
  /** Scripted Claude answers (the structured JSON), or a status number. */
  claude: (Record<string, unknown> | number)[];
  /** The JSON bodies sent to Claude. */
  claudeRequests: Record<string, any>[];
}

export function mockWeb(): Web {
  const web: Web = { pages: new Map(), requests: [], claude: [], claudeRequests: [] };
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    if (request.url === workosJwksUrl(env.WORKOS_CLIENT_ID)) return Response.json(await jwks);
    if (request.url.startsWith("https://api.anthropic.com/v1/messages")) return claudeResponse(web, request);
    web.requests.push([request.url, request.headers.get("User-Agent")]);
    const page = web.pages.get(request.url);
    if (page === undefined) return new Response("not found", { status: 404 });
    if (typeof page === "number") return new Response("nope", { status: page });
    return new Response(page, { headers: { "Content-Type": "text/html" } });
  });
  return web;
}

async function claudeResponse(web: Web, request: Request): Promise<Response> {
  const key = request.headers.get("x-api-key") ?? request.headers.get("Authorization")?.replace(/^Bearer /, "");
  if (!key || key !== env.ANTHROPIC_API_KEY) return Response.json({ type: "error", error: { type: "authentication_error", message: `bad key ${key}` } }, { status: 401 });
  web.claudeRequests.push(await request.json());
  const reply = web.claude.shift();
  if (reply === undefined) return Response.json({ type: "error", error: { type: "invalid_request_error", message: "No scripted reply left" } }, { status: 400 });
  if (typeof reply === "number") return Response.json({ type: "error", error: { type: "api_error", message: "down" } }, { status: reply });
  const text = JSON.stringify(reply);
  const events: [string, unknown][] = [
    ["message_start", { type: "message_start", message: { id: "msg_fake", type: "message", role: "assistant", model: "claude-fake", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 1 } } }],
    ["content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } }],
    ["content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } }],
    ["content_block_stop", { type: "content_block_stop", index: 0 }],
    ["message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 20 } }],
    ["message_stop", { type: "message_stop" }],
  ];
  return new Response(events.map(([e, d]) => `event: ${e}\ndata: ${JSON.stringify(d)}\n\n`).join(""), { headers: { "Content-Type": "text/event-stream" } });
}

/** Instagram's embed page for a post, trimmed to the parts we read. */
export function embedPage(creator: string, caption: string): string {
  return `<html><body><div class="Embed"><a class="UsernameText">${creator}</a>
<div class="Caption"><a class="CaptionUsername" href="#">${creator}</a><br><br>${caption.replace(/\n/g, "<br>")}<div class="CaptionComments">View all 1,579 comments</div></div></div></body></html>`;
}

export function recipePage(name: string, ingredients: string[], steps: string[]): string {
  const ld = { "@context": "https://schema.org", "@graph": [{ "@type": "WebPage" }, { "@type": "Recipe", name, recipeYield: ["4"], recipeIngredient: ingredients, recipeInstructions: steps.map((text) => ({ "@type": "HowToStep", text })) }] };
  return `<html><head><script type="application/ld+json">${JSON.stringify(ld)}</script></head><body>Lots of ads</body></html>`;
}

export const embedUrl = (shortcode: string) => `https://www.instagram.com/p/${shortcode}/embed/captioned/`;

/** A structured answer as Claude would return it. */
export function claudeRecipe(overrides: Record<string, unknown> = {}) {
  return {
    status: "recipe",
    reason: "The full recipe is in the caption.",
    source_used: "caption",
    completeness: "complete",
    missing: [],
    recipe: {
      title: "Banana Coconut Cookies",
      servings: 12,
      times: { prep_minutes: 10, cook_minutes: 15, total_minutes: null },
      ingredients: [
        { name: "ripe bananas", quantity: 2, unit: null, note: null },
        { name: "unsweetened shredded coconut", quantity: 2, unit: "cups", note: null },
        { name: "chocolate chips", quantity: 0.5, unit: "cup", note: "optional" },
      ],
      steps: [
        { text: "Heat the oven to 350°F and line a tray.", done_cue: null, duration_seconds: null },
        { text: "Mash the bananas and mix in the coconut.", done_cue: null, duration_seconds: null },
        { text: "Bake until set.", done_cue: "the coconut is golden", duration_seconds: 900 },
      ],
    },
    ...overrides,
  };
}

export function claudeOutcome(status: string, reason: string) {
  return { status, reason, source_used: "none", completeness: "none", missing: [], recipe: null };
}
