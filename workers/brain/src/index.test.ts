import { env, exports } from "cloudflare:workers";
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { Validator, type Schema } from "@cfworker/json-schema";
import { sessionSchema, type Recipe, type StreamEvent, type Turn } from "@sous/contracts";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { UserBrain } from "./brain";
import { BASE_PATH } from "./http";
import worker from "./index";
import { STAGE_PROMPT } from "./prompt";
import { demoRecipe } from "./seed";
import { fakeReflection, mockClaude, mockWorkos, readEvents, signToken, type WorkosMock } from "./testing";

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

describe("/sessions", () => {
  async function demoRecipeId(user: string): Promise<string> {
    const { recipes } = await (await call("/recipes", { user })).json<{ recipes: Recipe[] }>();
    return recipes.find((r) => r.title === demoRecipe.title)!.id!;
  }

  async function startSession(user: string): Promise<string> {
    const response = await call("/sessions", { user, method: "POST", body: { recipe_id: await demoRecipeId(user) } });
    expect(response.status).toBe(201);
    return (await response.json<{ id: string }>()).id;
  }

  async function turn(user: string, id: string, body: unknown): Promise<StreamEvent[]> {
    const response = await call(`/sessions/${id}/turns`, { user, method: "POST", body });
    expect(response.status).toBe(200);
    expect(response.headers.get("Content-Type")).toContain("text/event-stream");
    return readEvents<StreamEvent>(response);
  }

  const spoken = (events: StreamEvent[]) => events.flatMap((e) => (e.type === "text" ? [e.delta] : [])).join("");
  const toolCalls = (events: StreamEvent[]) => events.flatMap((e) => (e.type === "tool_call" ? [e.tool_call] : []));

  async function sessionRow(user: string, id: string) {
    return runInDurableObject(env.USER_BRAIN.get(env.USER_BRAIN.idFromName(user)), (_brain: UserBrain, state) => {
      const row = state.storage.sql.exec("SELECT * FROM sessions WHERE id = ?", id).one();
      return { stage: row.stage, turns: JSON.parse(row.turns as string) as Turn[], facts: JSON.parse(row.facts as string) as string[], messages: JSON.parse(row.messages as string) };
    });
  }

  it("starts a session with Sou's opening line, without calling Claude", async () => {
    const claude = mockClaude();
    const user = "user_sessionStart";
    const recipeId = await demoRecipeId(user);
    const response = await call("/sessions", { user, method: "POST", body: { recipe_id: recipeId } });
    expect(response.status).toBe(201);
    const session = await response.json<{ id: string; recipe_id: string; stage: string; opening_line: string }>();
    expect(session).toMatchObject({ recipe_id: recipeId, stage: "decide" });
    expect(session.opening_line).toContain(demoRecipe.title);
    expect(session.opening_line).not.toMatch(/[0-9]/);
    expect(claude.requests).toEqual([]);
    expect((await sessionRow(user, session.id)).turns).toEqual([{ role: "sous", at: expect.any(String), text: session.opening_line }]);
  });

  it("rejects bad session requests", async () => {
    const user = "user_sessionBad";
    expect((await call("/sessions", { user, method: "POST", body: { recipe_id: "nope" } })).status).toBe(404);
    expect((await call("/sessions", { user, method: "POST", body: {} })).status).toBe(400);
    expect((await call("/sessions", { user })).status).toBe(405);
    expect((await call("/sessions/nope/turns", { user, method: "POST", body: { text: "hi" } })).status).toBe(404);
    const id = await startSession(user);
    expect((await call(`/sessions/${id}/turns`, { user, method: "POST", body: {} })).status).toBe(400);
    expect((await call(`/sessions/${id}/turns`, { user, method: "POST", body: { text: "" } })).status).toBe(400);
    expect((await call(`/sessions/${id}/turns`, { user })).status).toBe(405);
  });

  it("keeps each user's sessions in their own brain", async () => {
    const id = await startSession("user_sessionOwner");
    expect((await call(`/sessions/${id}/turns`, { user: "user_sessionOther", method: "POST", body: { text: "hi" } })).status).toBe(404);
  });

  it("refuses to start without the Anthropic API key", async () => {
    const request = new Request<unknown, IncomingRequestCfProperties>(`https://build40for40.com${BASE_PATH}/sessions`, {
      method: "POST",
      headers: { Authorization: `Bearer ${await signToken({ sub: "user_sessionNokey" })}` },
      body: JSON.stringify({ recipe_id: "x" }),
    });
    expect((await worker.fetch(request, { ...env, ANTHROPIC_API_KEY: "" })).status).toBe(503);
  });

  it("walks the demo recipe through typed turns, with step and timer tool calls coming back", async () => {
    const user = "user_demoCook";
    const id = await startSession(user);
    const claude = mockClaude(
      {
        content: [
          { type: "text", text: "Lovely. Butter one side of each slice, right to the edges." },
          { type: "tool_use", id: "toolu_stage", name: "set_stage", input: { stage: "cook" } },
          { type: "tool_use", id: "toolu_step0", name: "go_to_step", input: { index: 0 } },
        ],
      },
      { content: [{ type: "text", text: "Shout when you're buttered." }] },
      {
        content: [
          { type: "text", text: "Cheese in the middle, into a dry pan on a medium heat. Three minutes on this side." },
          { type: "tool_use", id: "toolu_step1", name: "go_to_step", input: { index: 1 } },
          { type: "tool_use", id: "toolu_timer", name: "start_timer", input: { label: "first side", seconds: 180 } },
        ],
      },
      { content: [{ type: "tool_use", id: "toolu_cancel", name: "cancel_timer", input: { timer_id: "timer-1" } }] },
      { content: [{ type: "text", text: "Timer's off. Flip it over." }] },
    );

    const first = await turn(user, id, { text: "Everything's out, let's go." });
    expect(spoken(first)).toBe("Lovely. Butter one side of each slice, right to the edges.");
    expect(toolCalls(first)).toEqual([
      { id: "toolu_stage", name: "set_stage", input: { stage: "cook" } },
      { id: "toolu_step0", name: "go_to_step", input: { index: 0 } },
    ]);
    expect(first.at(-1)).toEqual({ type: "done", stop_reason: "tool_use" });

    const second = await turn(user, id, {
      tool_results: [
        { tool_call_id: "toolu_stage", content: "ok" },
        { tool_call_id: "toolu_step0", content: "ok" },
      ],
    });
    expect(spoken(second)).toBe("Shout when you're buttered.");
    expect(second.at(-1)).toEqual({ type: "done", stop_reason: "end_turn" });
    expect(claude.requests[1].messages.at(-1)).toEqual({
      role: "user",
      content: [
        { type: "tool_result", tool_use_id: "toolu_stage", content: "ok" },
        { type: "tool_result", tool_use_id: "toolu_step0", content: "ok" },
      ],
    });

    const third = await turn(user, id, { text: "Buttered. What next?" });
    expect(toolCalls(third)).toEqual([
      { id: "toolu_step1", name: "go_to_step", input: { index: 1 } },
      { id: "toolu_timer", name: "start_timer", input: { label: "first side", seconds: 180 } },
    ]);
    expect(third.at(-1)).toEqual({ type: "done", stop_reason: "tool_use" });

    const fourth = await turn(user, id, {
      tool_results: [
        { tool_call_id: "toolu_step1", content: "ok" },
        { tool_call_id: "toolu_timer", content: "timer-1" },
      ],
      text: "Actually it's already golden, cancel that timer.",
    });
    expect(toolCalls(fourth)).toEqual([{ id: "toolu_cancel", name: "cancel_timer", input: { timer_id: "timer-1" } }]);
    expect(claude.requests[3].messages.at(-1).content.at(-1)).toEqual({ type: "text", text: "Actually it's already golden, cancel that timer." });

    const fifth = await turn(user, id, { tool_results: [{ tool_call_id: "toolu_cancel", content: "ok" }] });
    expect(spoken(fifth)).toBe("Timer's off. Flip it over.");
    expect(fifth.at(-1)).toEqual({ type: "done", stop_reason: "end_turn" });

    const row = await sessionRow(user, id);
    expect(row.stage).toBe("cook");
    expect(row.turns.map((t) => t.role)).toEqual(["sous", "cook", "sous", "tool", "sous", "cook", "sous", "tool", "cook", "sous", "tool", "sous"]);
    expect(row.messages.map((m: { role: string }) => m.role)).toEqual(["user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant"]);
  });

  it("sends Claude the cached context and the live model settings", async () => {
    const user = "user_sessionRequest";
    await call("/me", { user, method: "PATCH", body: { preferences: { avoid: ["coriander"] } } });
    const id = await startSession(user);
    const claude = mockClaude({ content: [{ type: "text", text: "Hello!" }] });
    await turn(user, id, { text: "Hi Sou" });

    const [request] = claude.requests;
    expect(request).toMatchObject({ model: "claude-sonnet-5-5", stream: true, thinking: { type: "between_tools" }, output_config: { effort: "low" }, cache_control: { type: "ephemeral" } });
    expect(request.tools.map((t: { name: string }) => t.name)).toEqual(["start_timer", "cancel_timer", "go_to_step", "set_stage", "show", "note"]);
    expect(request.system[0]).toEqual({ type: "text", text: STAGE_PROMPT });
    expect(request.system[1].cache_control).toEqual({ type: "ephemeral" });
    expect(request.system[1].text).toContain("coriander");
    expect(request.system[1].text).toContain(demoRecipe.title);
    expect(request.messages).toEqual([{ role: "user", content: [{ type: "text", text: "Hi Sou" }] }]);
  });

  it("runs note in the brain, saves the fact and carries on without the phone", async () => {
    const user = "user_sessionNote";
    const id = await startSession(user);
    const claude = mockClaude(
      { content: [{ type: "tool_use", id: "toolu_note", name: "note", input: { fact: "Hates coriander" } }] },
      { content: [{ type: "text", text: "Noted, no coriander ever." }] },
    );
    const events = await turn(user, id, { text: "I can't stand coriander." });
    expect(toolCalls(events)).toEqual([]);
    expect(spoken(events)).toBe("Noted, no coriander ever.");
    expect(events.at(-1)).toEqual({ type: "done", stop_reason: "end_turn" });
    expect(claude.requests[1].messages.at(-1)).toEqual({ role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_note", content: "saved" }] });

    const row = await sessionRow(user, id);
    expect(row.facts).toEqual(["Hates coriander"]);
    expect(row.turns.slice(-3)).toEqual([
      { role: "sous", at: expect.any(String), tool_calls: [{ id: "toolu_note", name: "note", input: { fact: "Hates coriander" } }] },
      { role: "tool", at: expect.any(String), tool_results: [{ tool_call_id: "toolu_note", content: "saved" }] },
      { role: "sous", at: expect.any(String), text: "Noted, no coriander ever." },
    ]);
  });

  it("answers note alongside client tools once the phone sends its results", async () => {
    const user = "user_sessionMixed";
    const id = await startSession(user);
    const claude = mockClaude(
      {
        content: [
          { type: "tool_use", id: "toolu_note2", name: "note", input: { fact: "Owns one frying pan" } },
          { type: "tool_use", id: "toolu_show", name: "show", input: { view: "ingredients" } },
        ],
      },
      { content: [{ type: "text", text: "There's your list." }] },
    );
    const events = await turn(user, id, { text: "I've only got one pan, show me the list." });
    expect(toolCalls(events)).toEqual([{ id: "toolu_show", name: "show", input: { view: "ingredients" } }]);
    expect(events.at(-1)).toEqual({ type: "done", stop_reason: "tool_use" });
    expect(claude.requests).toHaveLength(1);

    const owed = await call(`/sessions/${id}/turns`, { user, method: "POST", body: { text: "hello?" } });
    expect(owed.status).toBe(409);
    expect(await owed.json()).toEqual({ error: "tool_results_required", tool_call_ids: ["toolu_show"] });

    await turn(user, id, { tool_results: [{ tool_call_id: "toolu_show", content: "ok" }] });
    expect(claude.requests[1].messages.at(-1)).toEqual({
      role: "user",
      content: [
        { type: "tool_result", tool_use_id: "toolu_note2", content: "saved" },
        { type: "tool_result", tool_use_id: "toolu_show", content: "ok" },
      ],
    });
    expect((await sessionRow(user, id)).facts).toEqual(["Owns one frying pan"]);
  });

  it("rejects tool results nobody asked for", async () => {
    const user = "user_sessionUnasked";
    const id = await startSession(user);
    const response = await call(`/sessions/${id}/turns`, { user, method: "POST", body: { tool_results: [{ tool_call_id: "toolu_x", content: "ok" }] } });
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "unexpected_tool_results" });
  });

  it("streams an error and saves nothing when Claude fails, so the turn can be retried", async () => {
    const user = "user_sessionError";
    const id = await startSession(user);
    const claude = mockClaude(
      { status: 400, message: "bad request" },
      { breakAfter: [{ type: "text", text: "Right, so" }] },
      { content: [{ type: "text", text: "Sorry about that." }], stop_reason: "refusal" },
      { content: [{ type: "text", text: "Back with you." }] },
    );
    const before = await sessionRow(user, id);

    for (let attempt = 0; attempt < 3; attempt++) {
      const events = await turn(user, id, { text: "Hello?" });
      expect(events.at(-1)).toEqual({ type: "error", message: expect.any(String) });
      expect(events.some((e) => e.type === "done")).toBe(false);
      expect(await sessionRow(user, id)).toEqual(before);
    }

    const events = await turn(user, id, { text: "Hello?" });
    expect(spoken(events)).toBe("Back with you.");
    expect(claude.requests.at(-1)!.messages).toEqual([{ role: "user", content: [{ type: "text", text: "Hello?" }] }]);
  });

  it("refuses turns once the session has ended", async () => {
    const user = "user_sessionEnded";
    const id = await startSession(user);
    await runInDurableObject(env.USER_BRAIN.get(env.USER_BRAIN.idFromName(user)), (_brain: UserBrain, state) => {
      state.storage.sql.exec("UPDATE sessions SET ended_at = ? WHERE id = ?", new Date().toISOString(), id);
    });
    const response = await call(`/sessions/${id}/turns`, { user, method: "POST", body: { text: "One more thing" } });
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "session_ended" });
  });

  describe("ending a session", () => {
    const stub = (user: string) => env.USER_BRAIN.get(env.USER_BRAIN.idFromName(user));
    const { $id, ...withoutId } = sessionSchema;
    const sessionValidator = new Validator(withoutId as unknown as Schema, "2020-12", false);

    it("closes the session straight away and reflects in the background, and the next session picks it up", async () => {
      const user = "user_reflectFull";
      const id = await startSession(user);
      mockClaude(
        { content: [{ type: "tool_use", id: "toolu_hate", name: "note", input: { fact: "Hates coriander" } }] },
        { content: [{ type: "text", text: "Got it. Swap the cheddar for red leicester, that'll melt lovely." }] },
      );
      await turn(user, id, { text: "No coriander ever please, and I've only got red leicester." });

      const claude = mockClaude({ content: [{ type: "text", text: JSON.stringify(fakeReflection) }] });
      const ended = await call(`/sessions/${id}/end`, { user, method: "POST", body: { rating: 5, notes: "Lush, but a bit pale." } });
      expect(ended.status).toBe(202);
      expect(await ended.json()).toEqual({ id, ended_at: expect.any(String), rating: 5, notes: "Lush, but a bit pale.", reflection_status: "pending" });
      expect(claude.requests).toEqual([]);

      const pending = await (await call(`/sessions/${id}`, { user })).json<{ session: unknown; reflection: unknown; reflection_status: string }>();
      expect(pending).toMatchObject({ reflection: null, reflection_status: "pending", reflected_at: null });
      expect(sessionValidator.validate(pending.session).valid).toBe(true);
      expect(pending.session).toMatchObject({ id, rating: 5, notes: "Lush, but a bit pale.", facts: ["Hates coriander"] });

      expect(await runDurableObjectAlarm(stub(user))).toBe(true);
      expect(claude.requests).toHaveLength(1);
      expect(claude.requests[0]).toMatchObject({ model: "claude-opus-5-5", output_config: { format: { type: "json_schema" } } });
      const sent = claude.requests[0].messages[0].content as string;
      for (const text of ["Cook: No coriander ever please, and I've only got red leicester.", "- Hates coriander", "5 out of 5", "Lush, but a bit pale.", demoRecipe.title]) {
        expect(sent).toContain(text);
      }

      const done = await (await call(`/sessions/${id}`, { user })).json<{ session: { turns: Turn[] }; reflection: Record<string, unknown>; reflection_status: string; reflected_at: string }>();
      expect(done.reflection_status).toBe("done");
      expect(done.reflected_at).toEqual(expect.any(String));
      expect(done.session.turns.map((t) => t.role)).toEqual(["sous", "cook", "sous", "tool", "sous"]);
      expect(done.reflection).toMatchObject({
        rating: 5,
        summary: "Golden toastie, cheese a touch underdone.",
        preferences: ["Hates coriander"],
        ingredients: ["bread", "red leicester"],
        cuisine: "british",
        note: expect.stringMatching(/^sessions\/\d{4}-\d{2}-\d{2}-fake-demo-cheese-toastie-[0-9a-f]{8}\.md$/),
      });

      const me = await (await call("/me", { user })).json<{ about: string }>();
      expect(me.about).toContain("## Learned while cooking\n\n- Hates coriander");

      const next = await startSession(user);
      const nextClaude = mockClaude({ content: [{ type: "text", text: "Back for another?" }] });
      await turn(user, next, { text: "Toastie again" });
      const context = nextClaude.requests[0].system[1].text as string;
      for (const text of [
        "Hates coriander",
        "Golden toastie, cheese a touch underdone.",
        "red leicester instead of cheddar: Melted well",
        `## ${done.reflection.note}`,
        "## ingredients/red-leicester.md",
        "## cuisines/british.md",
      ]) {
        expect(context).toContain(text);
      }
    });

    it("needs no body, and won't end a session twice or take turns after", async () => {
      const user = "user_reflectTwice";
      const id = await startSession(user);
      expect((await call(`/sessions/${id}/end`, { user, method: "POST" })).status).toBe(202);
      const again = await call(`/sessions/${id}/end`, { user, method: "POST", body: { rating: 3 } });
      expect(again.status).toBe(409);
      expect(await again.json()).toEqual({ error: "session_ended" });
      expect((await call(`/sessions/${id}/turns`, { user, method: "POST", body: { text: "Hi" } })).status).toBe(409);
      expect(await (await call(`/sessions/${id}`, { user })).json()).toMatchObject({ session: { ended_at: expect.any(String) }, reflection_status: "pending" });
      mockClaude({ content: [{ type: "text", text: JSON.stringify(fakeReflection) }] });
      await runDurableObjectAlarm(stub(user));
    });

    it("rejects bad requests and keeps sessions to their owner", async () => {
      const user = "user_reflectBad";
      const id = await startSession(user);
      expect((await call(`/sessions/${id}/end`, { user, method: "POST", body: { rating: 6 } })).status).toBe(400);
      expect((await call(`/sessions/${id}/end`, { user, method: "POST", body: { mood: "great" } })).status).toBe(400);
      expect((await call(`/sessions/${id}/end`, { user, method: "POST", body: "{nope" })).status).toBe(400);
      expect((await call(`/sessions/${id}/end`, { user })).status).toBe(405);
      expect((await call(`/sessions/${id}`, { user, method: "DELETE" })).status).toBe(405);
      expect((await call("/sessions/nope/end", { user, method: "POST" })).status).toBe(404);
      expect((await call("/sessions/nope", { user })).status).toBe(404);
      expect((await call(`/sessions/${id}`, { user: "user_reflectOther" })).status).toBe(404);
      expect((await call(`/sessions/${id}/end`, { user: "user_reflectOther", method: "POST" })).status).toBe(404);
      expect(await (await call(`/sessions/${id}`, { user })).json()).toMatchObject({ reflection_status: "not_ended", reflection: null });
    });
  });
});
