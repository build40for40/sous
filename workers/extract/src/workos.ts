import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";

// Same verification as workers/brain/src/workos.ts: the shared WorkOS AuthKit application's JWKS.
const API = "https://api.workos.com";
const USER_ID = /^user_[A-Za-z0-9]+$/;
const keySets = new Map<string, JWTVerifyGetKey>();

export const workosIssuer = (clientId: string) => `${API}/user_management/${clientId}`;
export const workosJwksUrl = (clientId: string) => `${API}/sso/jwks/${clientId}`;

function keysFor(clientId: string): JWTVerifyGetKey {
  let keys = keySets.get(clientId);
  if (!keys) {
    keys = createRemoteJWKSet(new URL(workosJwksUrl(clientId)));
    keySets.set(clientId, keys);
  }
  return keys;
}

/** The WorkOS user id from a valid Bearer token, or null. Never trusts a user id from the body. */
export async function authenticate(request: Request, clientId: string): Promise<string | null> {
  const token = request.headers.get("Authorization")?.match(/^Bearer (\S+)$/)?.[1];
  if (!token) return null;
  try {
    const { payload } = await jwtVerify(token, keysFor(clientId), {
      issuer: workosIssuer(clientId),
      algorithms: ["RS256"],
      requiredClaims: ["sub", "exp", "iat"],
    });
    return typeof payload.sub === "string" && USER_ID.test(payload.sub) ? payload.sub : null;
  } catch {
    return null;
  }
}
