import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mockWorkos, otherKey, signToken, type WorkosMock } from "./testing";
import { authenticate, deleteWorkosUser } from "./workos";

const withAuth = (value?: string) => new Request("https://example.com/", { headers: value ? { Authorization: value } : {} });
const clientId = env.WORKOS_CLIENT_ID;

let workos: WorkosMock;
beforeEach(() => {
  workos = mockWorkos();
});
afterEach(() => {
  vi.restoreAllMocks();
});

describe("authenticate", () => {
  it("returns the sub of a valid WorkOS access token", async () => {
    expect(await authenticate(withAuth(`Bearer ${await signToken({ sub: "user_alice" })}`), clientId)).toBe("user_alice");
  });

  it("rejects a missing or non-Bearer Authorization header", async () => {
    expect(await authenticate(withAuth(), clientId)).toBeNull();
    expect(await authenticate(withAuth(`Basic ${await signToken()}`), clientId)).toBeNull();
    expect(await authenticate(withAuth("Bearer not-a-jwt"), clientId)).toBeNull();
  });

  it("rejects an expired token", async () => {
    const expired = await signToken({ expiresAt: Math.floor(Date.now() / 1000) - 10 });
    expect(await authenticate(withAuth(`Bearer ${expired}`), clientId)).toBeNull();
  });

  it("rejects a token from another issuer", async () => {
    const token = await signToken({ issuer: "https://api.workos.com/user_management/client_someone_else" });
    expect(await authenticate(withAuth(`Bearer ${token}`), clientId)).toBeNull();
  });

  it("rejects a token signed by a key outside the JWKS", async () => {
    const token = await signToken({ key: await otherKey });
    expect(await authenticate(withAuth(`Bearer ${token}`), clientId)).toBeNull();
  });

  it("rejects a sub that isn't a WorkOS user id", async () => {
    const token = await signToken({ sub: "../admin" });
    expect(await authenticate(withAuth(`Bearer ${token}`), clientId)).toBeNull();
  });
});

describe("deleteWorkosUser", () => {
  it("deletes the user with the API key", async () => {
    expect(await deleteWorkosUser("user_alice", env.WORKOS_API_KEY)).toBe(true);
    expect(workos.deletedUsers).toEqual(["user_alice"]);
  });

  it("treats an already deleted user as done", async () => {
    workos.deleteStatus = 404;
    expect(await deleteWorkosUser("user_alice", env.WORKOS_API_KEY)).toBe(true);
  });

  it("reports a WorkOS failure", async () => {
    workos.deleteStatus = 500;
    expect(await deleteWorkosUser("user_alice", env.WORKOS_API_KEY)).toBe(false);
  });
});
