import { env, exports } from "cloudflare:workers";
import type { Recipe } from "@sous/contracts";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BASE_PATH } from "./http";
import worker from "./index";
import { mockWorkos, signToken, type WorkosMock } from "./testing";

let workos: WorkosMock;
beforeEach(() => {
  workos = mockWorkos();
});
afterEach(() => {
  vi.restoreAllMocks();
});

async function call(path: string, { user, method = "GET", body, token }: { user?: string; method?: string; body?: unknown; token?: string } = {}) {
  const headers = new Headers();
  const bearer = token ?? (user ? await signToken({ sub: user }) : undefined);
  if (bearer) headers.set("Authorization", `Bearer ${bearer}`);
  if (body !== undefined) headers.set("Content-Type", "application/json");
  return exports.default.fetch(`https://build40for40.com${BASE_PATH}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
}

const recipe = {
  title: "Fake Test Pancakes",
  source_url: "https://example.com/sous/fake-test-pancakes",
  ingredients: [{ name: "flour", quantity: 100, unit: "g" }],
  steps: [{ text: "Whisk and fry.", done_cue: "Bubbles on top." }],
};

describe("auth", () => {
  it("rejects a request without a token", async () => {
    const response = await call("/recipes");
    expect(response.status).toBe(401);
    expect(response.headers.get("WWW-Authenticate")).toContain("Bearer");
    expect(await response.json()).toEqual({ error: "sign_in_required" });
  });

  it("rejects an expired token", async () => {
    const token = await signToken({ sub: "user_alice", expiresAt: Math.floor(Date.now() / 1000) - 1 });
    expect((await call("/recipes", { token })).status).toBe(401);
  });

  it("rejects a token from another issuer", async () => {
    const token = await signToken({ sub: "user_alice", issuer: "https://evil.example.com" });
    expect((await call("/me", { token })).status).toBe(401);
  });

  it("only serves the API base path", async () => {
    const response = await exports.default.fetch("https://build40for40.com/sous/recipes");
    expect(response.status).toBe(404);
  });

  it("returns 404 for unknown routes once signed in", async () => {
    expect((await call("/nope", { user: "user_routes" })).status).toBe(404);
    expect((await call("/recipes/%E0", { user: "user_routes" })).status).toBe(404);
  });
});

describe("/me", () => {
  it("returns the seeded profile for the signed-in user", async () => {
    const response = await call("/me", { user: "user_me1" });
    expect(response.status).toBe(200);
    const me = await response.json<{ id: string; preferences: Record<string, unknown>; about: string }>();
    expect(me.id).toBe("user_me1");
    expect(me.preferences).toEqual({ units: "metric", diet: [], avoid: [] });
    expect(me.about).toContain("# About me");
  });

  it("merges preference changes, removes nulls and replaces about", async () => {
    const response = await call("/me", {
      user: "user_me2",
      method: "PATCH",
      body: { preferences: { avoid: ["coriander"], units: null, spice: "hot" }, about: "# About me\n\nLoves a toastie." },
    });
    expect(response.status).toBe(200);
    const me = await response.json<{ preferences: Record<string, unknown>; about: string }>();
    expect(me.preferences).toEqual({ diet: [], avoid: ["coriander"], spice: "hot" });
    expect(me.about).toBe("# About me\n\nLoves a toastie.");
    expect(await (await call("/me", { user: "user_me2" })).json()).toMatchObject({ preferences: me.preferences });
  });

  it("rejects bad patches, including a user id in the body", async () => {
    expect((await call("/me", { user: "user_me3", method: "PATCH", body: { id: "user_someone_else" } })).status).toBe(400);
    expect((await call("/me", { user: "user_me3", method: "PATCH", body: { preferences: [] } })).status).toBe(400);
    expect((await call("/me", { user: "user_me3", method: "PATCH", body: "{nope" })).status).toBe(400);
    expect((await call("/me", { user: "user_me3", method: "PUT" })).status).toBe(405);
  });

  it("DELETE wipes the user's brain and deletes the WorkOS user", async () => {
    const created = await (await call("/recipes", { user: "user_gone", method: "POST", body: recipe })).json<Recipe>();
    await call("/me", { user: "user_gone", method: "PATCH", body: { about: "secret notes" } });

    const response = await call("/me", { user: "user_gone", method: "DELETE" });
    expect(response.status).toBe(204);
    expect(workos.deletedUsers).toEqual(["user_gone"]);

    expect((await call(`/recipes/${created.id}`, { user: "user_gone" })).status).toBe(404);
    expect(await (await call("/me", { user: "user_gone" })).json()).not.toMatchObject({ about: "secret notes" });
  });

  it("DELETE reports a WorkOS failure", async () => {
    workos.deleteStatus = 500;
    expect((await call("/me", { user: "user_fail", method: "DELETE" })).status).toBe(502);
  });

  it("DELETE refuses to start without the WorkOS API key", async () => {
    await call("/recipes", { user: "user_nokey", method: "POST", body: recipe });
    const request = new Request<unknown, IncomingRequestCfProperties>(`https://build40for40.com${BASE_PATH}/me`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${await signToken({ sub: "user_nokey" })}` },
    });
    const response = await worker.fetch(request, { ...env, WORKOS_API_KEY: "" });
    expect(response.status).toBe(503);
    expect(workos.deletedUsers).toEqual([]);
    const { recipes } = await (await call("/recipes", { user: "user_nokey" })).json<{ recipes: Recipe[] }>();
    expect(recipes).toHaveLength(2);
  });
});

describe("/recipes", () => {
  it("starts with one fake demo recipe", async () => {
    const { recipes } = await (await call("/recipes", { user: "user_fresh" })).json<{ recipes: Recipe[] }>();
    expect(recipes).toHaveLength(1);
    expect(recipes[0].title).toMatch(/fake demo/i);
  });

  it("creates, lists, gets and deletes a recipe", async () => {
    const user = "user_cook";
    const createdResponse = await call("/recipes", { user, method: "POST", body: { ...recipe, id: "client-id", slug: "client-slug" } });
    expect(createdResponse.status).toBe(201);
    const created = await createdResponse.json<Recipe>();
    expect(created).toMatchObject({ ...recipe, slug: "fake-test-pancakes" });
    expect(created.id).not.toBe("client-id");
    expect(created.created_at).toBe(created.updated_at);

    const { recipes } = await (await call("/recipes", { user })).json<{ recipes: Recipe[] }>();
    expect(recipes.map((r) => r.id)).toContain(created.id);
    expect(recipes[0].id).toBe(created.id);

    expect(await (await call(`/recipes/${created.id}`, { user })).json()).toEqual(created);

    expect((await call(`/recipes/${created.id}`, { user, method: "DELETE" })).status).toBe(204);
    expect((await call(`/recipes/${created.id}`, { user })).status).toBe(404);
    expect((await call(`/recipes/${created.id}`, { user, method: "DELETE" })).status).toBe(404);
  });

  it("gives each recipe a unique slug", async () => {
    const user = "user_slugs";
    const first = await (await call("/recipes", { user, method: "POST", body: recipe })).json<Recipe>();
    const second = await (await call("/recipes", { user, method: "POST", body: recipe })).json<Recipe>();
    expect([first.slug, second.slug]).toEqual(["fake-test-pancakes", "fake-test-pancakes-2"]);
  });

  it("rejects a recipe that breaks the contract", async () => {
    const response = await call("/recipes", { user: "user_bad", method: "POST", body: { title: "No steps", ingredients: [] } });
    expect(response.status).toBe(400);
    const body = await response.json<{ error: string; issues: unknown[] }>();
    expect(body.error).toBe("invalid_recipe");
    expect(body.issues.length).toBeGreaterThan(0);
  });

  it("keeps each user's recipes in their own brain", async () => {
    const alices = await (await call("/recipes", { user: "user_alice", method: "POST", body: recipe })).json<Recipe>();
    const { recipes: bobs } = await (await call("/recipes", { user: "user_bob" })).json<{ recipes: Recipe[] }>();
    expect(bobs.map((r) => r.id)).not.toContain(alices.id);
    expect((await call(`/recipes/${alices.id}`, { user: "user_bob" })).status).toBe(404);
    expect((await call(`/recipes/${alices.id}`, { user: "user_bob", method: "DELETE" })).status).toBe(404);
    expect((await call(`/recipes/${alices.id}`, { user: "user_alice" })).status).toBe(200);
  });
});
