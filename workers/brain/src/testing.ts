import { env } from "cloudflare:workers";
import { exportJWK, generateKeyPair, SignJWT, type CryptoKey } from "jose";
import { vi } from "vitest";
import { workosIssuer, workosJwksUrl, workosUserUrl } from "./workos";

const KID = "test-key";
const keyPair = generateKeyPair("RS256", { extractable: true });
const jwks = keyPair.then(async ({ publicKey }) => ({ keys: [{ ...(await exportJWK(publicKey)), kid: KID, alg: "RS256", use: "sig" }] }));

export const otherKey = generateKeyPair("RS256").then((pair) => pair.privateKey);

export interface TokenOptions {
  sub?: string;
  issuer?: string;
  expiresAt?: number;
  key?: CryptoKey;
}

export async function signToken({ sub = "user_alice", issuer, expiresAt, key }: TokenOptions = {}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ sid: "session_fake" })
    .setProtectedHeader({ alg: "RS256", kid: KID })
    .setSubject(sub)
    .setIssuer(issuer ?? workosIssuer(env.WORKOS_CLIENT_ID))
    .setIssuedAt(now - 60)
    .setExpirationTime(expiresAt ?? now + 300)
    .sign(key ?? (await keyPair).privateKey);
}

export interface WorkosMock {
  deletedUsers: string[];
  deleteStatus: number;
}

export type ClaudeBlock = { type: "text"; text: string } | { type: "tool_use"; id?: string; name: string; input: unknown };

/** One scripted Messages API response: a streamed reply, an HTTP error, or a stream that breaks partway. */
export type ClaudeReply =
  | { content: ClaudeBlock[]; stop_reason?: "end_turn" | "tool_use" | "max_tokens" | "refusal" }
  | { status: number; message: string }
  | { breakAfter: ClaudeBlock[] };

export interface ClaudeMock {
  /** The JSON bodies sent to the Messages API, in order. */
  requests: Record<string, any>[];
  replies: ClaudeReply[];
}

const ANTHROPIC_MESSAGES_URL = "https://api.anthropic.com/v1/messages";
let workosMock: WorkosMock | null = null;
let claudeMock: ClaudeMock | null = null;
let toolUseCount = 0;

function installFetchMock(): void {
  if (vi.isMockFunction(globalThis.fetch)) return;
  workosMock = null;
  claudeMock = null;
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    if (request.url.startsWith(ANTHROPIC_MESSAGES_URL) && claudeMock) return claudeResponse(claudeMock, request);
    if (workosMock) {
      if (request.method === "GET" && request.url === workosJwksUrl(env.WORKOS_CLIENT_ID)) return Response.json(await jwks);
      const userId = decodeURIComponent(request.url.split("/").pop() ?? "");
      if (request.method === "DELETE" && request.url === workosUserUrl(userId)) {
        if (request.headers.get("Authorization") !== `Bearer ${env.WORKOS_API_KEY}`) return new Response(null, { status: 401 });
        workosMock.deletedUsers.push(userId);
        return new Response(null, { status: workosMock.deleteStatus });
      }
    }
    throw new Error(`Unexpected fetch: ${request.method} ${request.url}`);
  });
}

/** Stands in for WorkOS: serves the test JWKS, records user deletions and fails on any other outbound request. */
export function mockWorkos(): WorkosMock {
  installFetchMock();
  workosMock = { deletedUsers: [], deleteStatus: 202 };
  return workosMock;
}

/** Stands in for the Claude Messages API, answering each request with the next scripted reply as a stream. */
export function mockClaude(...replies: ClaudeReply[]): ClaudeMock {
  installFetchMock();
  claudeMock = { requests: [], replies };
  return claudeMock;
}

async function claudeResponse(mock: ClaudeMock, request: Request): Promise<Response> {
  const key = request.headers.get("x-api-key") ?? request.headers.get("Authorization")?.replace(/^Bearer /, "");
  if (key !== env.ANTHROPIC_API_KEY) return Response.json(apiError("authentication_error", "bad key"), { status: 401 });
  mock.requests.push(await request.json());
  const reply = mock.replies.shift();
  if (!reply) return Response.json(apiError("invalid_request_error", "No scripted reply left"), { status: 400 });
  if ("status" in reply) return Response.json(apiError("api_error", reply.message), { status: reply.status });

  const blocks = "breakAfter" in reply ? reply.breakAfter : reply.content;
  const events: [string, unknown][] = [
    ["message_start", { type: "message_start", message: { id: "msg_fake", type: "message", role: "assistant", model: "claude-fake", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 } } }],
  ];
  blocks.forEach((block, index) => {
    if (block.type === "text") {
      events.push(["content_block_start", { type: "content_block_start", index, content_block: { type: "text", text: "" } }]);
      const middle = Math.ceil(block.text.length / 2);
      for (const text of [block.text.slice(0, middle), block.text.slice(middle)]) {
        if (text) events.push(["content_block_delta", { type: "content_block_delta", index, delta: { type: "text_delta", text } }]);
      }
    } else {
      const id = block.id ?? `toolu_fake_${++toolUseCount}`;
      events.push(["content_block_start", { type: "content_block_start", index, content_block: { type: "tool_use", id, name: block.name, input: {} } }]);
      events.push(["content_block_delta", { type: "content_block_delta", index, delta: { type: "input_json_delta", partial_json: JSON.stringify(block.input) } }]);
    }
    events.push(["content_block_stop", { type: "content_block_stop", index }]);
  });
  if ("breakAfter" in reply) {
    events.push(["error", { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }]);
  } else {
    const stop_reason = reply.stop_reason ?? (blocks.some((b) => b.type === "tool_use") ? "tool_use" : "end_turn");
    events.push(["message_delta", { type: "message_delta", delta: { stop_reason, stop_sequence: null }, usage: { output_tokens: 20 } }]);
    events.push(["message_stop", { type: "message_stop" }]);
  }
  const body = events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join("");
  return new Response(body, { headers: { "Content-Type": "text/event-stream" } });
}

function apiError(type: string, message: string) {
  return { type: "error", error: { type, message } };
}

/** A raw reflection as Opus might return it, untidy on purpose. */
export const fakeReflection = {
  rating: 3,
  summary: "  Golden toastie,   cheese a touch underdone. ",
  worked: ["Buttering edge to edge", "Buttering edge to edge", " "],
  failed: ["Lower the heat so the cheese melts first"],
  substitutions: [
    { original: "Cheddar", replacement: "Red Leicester", outcome: "Melted well" },
    { original: "", replacement: "nothing", outcome: "" },
  ],
  preferences: ["Hates coriander"],
  ingredients: ["Bread", "bread ", "Red Leicester"],
  techniques: ["Toasting"],
  cuisine: "British",
};

/** Reads a server-sent event stream into its events' data. */
export async function readEvents<T = unknown>(response: Response): Promise<T[]> {
  const text = await response.text();
  return text
    .split("\n\n")
    .filter(Boolean)
    .map((chunk) => {
      const [eventLine, dataLine] = chunk.split("\n");
      const data = JSON.parse(dataLine.replace(/^data: /, "")) as { type: string };
      if (eventLine !== `event: ${data.type}`) throw new Error(`Event name ${eventLine} doesn't match ${data.type}`);
      return data as T;
    });
}
