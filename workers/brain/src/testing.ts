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

/** Stands in for WorkOS: serves the test JWKS, records user deletions and fails on any other outbound request. */
export function mockWorkos(): WorkosMock {
  const mock: WorkosMock = { deletedUsers: [], deleteStatus: 202 };
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const request = new Request(input, init);
    if (request.method === "GET" && request.url === workosJwksUrl(env.WORKOS_CLIENT_ID)) return Response.json(await jwks);
    const userId = decodeURIComponent(request.url.split("/").pop() ?? "");
    if (request.method === "DELETE" && request.url === workosUserUrl(userId)) {
      if (request.headers.get("Authorization") !== `Bearer ${env.WORKOS_API_KEY}`) return new Response(null, { status: 401 });
      mock.deletedUsers.push(userId);
      return new Response(null, { status: mock.deleteStatus });
    }
    throw new Error(`Unexpected fetch: ${request.method} ${request.url}`);
  });
  return mock;
}
