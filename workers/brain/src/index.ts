import { BASE_PATH, error, HttpError, json, readJson } from "./http";
import { parseProfilePatch } from "./profile";
import { validateRecipe } from "./recipes";
import { parseEndRequest } from "./reflection";
import { parseNewSession, parseTurnRequest } from "./sessions";
import { authenticate, deleteWorkosUser } from "./workos";

import type { UserBrain } from "./brain";

export { UserBrain } from "./brain";

const MAX_BODY_BYTES = 256 * 1024;
const MAX_TURN_BYTES = 32 * 1024;

// The generated stub types recurse too deeply on JSON preferences, so the stub is typed from the class directly.
type Rpc<T> = { [K in keyof T]: T[K] extends (...args: infer A) => infer R ? (...args: A) => Promise<Awaited<R>> : never };
type Brain = Rpc<Pick<UserBrain, "getProfile" | "updateProfile" | "wipe" | "listRecipes" | "getRecipe" | "createRecipe" | "deleteRecipe" | "createSession" | "takeTurn" | "endSession" | "getSession" | "listHistory" | "suggest">>;

export default {
  async fetch(request, env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname !== BASE_PATH && !pathname.startsWith(`${BASE_PATH}/`)) return error(404, "not_found");

    const userId = await authenticate(request, env.WORKOS_CLIENT_ID);
    if (!userId) return error(401, "sign_in_required", undefined, { "WWW-Authenticate": 'Bearer realm="sous"' });

    const brain = env.USER_BRAIN.get(env.USER_BRAIN.idFromName(userId)) as unknown as Brain;
    try {
      return await route(request, pathname.slice(BASE_PATH.length), userId, brain, env);
    } catch (e) {
      if (e instanceof HttpError) return e.toResponse();
      throw e;
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, path: string, userId: string, brain: Brain, env: Env): Promise<Response> {
  const { method } = request;

  if (path === "/me") {
    if (method === "GET") return json({ id: userId, ...(await brain.getProfile()) });
    if (method === "PATCH") {
      const profile = await brain.updateProfile(parseProfilePatch(await readJson(request, MAX_BODY_BYTES)));
      if (!profile) return error(400, "invalid_profile", { message: "preferences are too big." });
      return json({ id: userId, ...profile });
    }
    if (method === "DELETE") return deleteAccount(userId, brain, env);
    return methodNotAllowed("GET, PATCH, DELETE");
  }

  if (path === "/recipes") {
    if (method === "GET") return json({ recipes: await brain.listRecipes() });
    if (method === "POST") {
      const result = validateRecipe(await readJson(request, MAX_BODY_BYTES));
      if (!result.ok) return error(400, "invalid_recipe", { issues: result.issues });
      return json(await brain.createRecipe(result.recipe), 201);
    }
    return methodNotAllowed("GET, POST");
  }

  const id = path.match(/^\/recipes\/([A-Za-z0-9-]+)$/)?.[1];
  if (id) {
    if (method === "GET") {
      const recipe = await brain.getRecipe(id);
      return recipe ? json(recipe) : error(404, "recipe_not_found");
    }
    if (method === "DELETE") return (await brain.deleteRecipe(id)) ? new Response(null, { status: 204 }) : error(404, "recipe_not_found");
    return methodNotAllowed("GET, DELETE");
  }

  if (path === "/history") {
    if (method !== "GET") return methodNotAllowed("GET");
    return json({ cooks: await brain.listHistory() });
  }

  if (path === "/suggest") {
    if (method !== "GET") return methodNotAllowed("GET");
    const suggestions = await brain.suggest();
    if (suggestions === "suggestions_unavailable") return error(503, suggestions);
    if (suggestions === "suggestions_failed") return error(502, suggestions);
    return json({ suggestions });
  }

  if (path === "/sessions") {
    if (method !== "POST") return methodNotAllowed("POST");
    if (!env.ANTHROPIC_API_KEY) return error(503, "live_sessions_unavailable");
    const session = await brain.createSession(parseNewSession(await readJson(request, MAX_BODY_BYTES)).recipe_id);
    return session ? json(session, 201) : error(404, "recipe_not_found");
  }

  const sessionMatch = path.match(/^\/sessions\/([A-Za-z0-9-]+)(?:\/(turns|end))?$/);
  if (sessionMatch) {
    const [, sessionId, action] = sessionMatch;
    if (action === "turns") {
      if (method !== "POST") return methodNotAllowed("POST");
      if (!env.ANTHROPIC_API_KEY) return error(503, "live_sessions_unavailable");
      return brain.takeTurn(sessionId, parseTurnRequest(await readJson(request, MAX_TURN_BYTES)));
    }
    if (action === "end") {
      if (method !== "POST") return methodNotAllowed("POST");
      const body = request.body && request.headers.get("Content-Length") !== "0" ? await readJson(request, MAX_BODY_BYTES) : {};
      const ended = await brain.endSession(sessionId, parseEndRequest(body));
      if (typeof ended === "string") return error(ended === "session_not_found" ? 404 : 409, ended);
      return json(ended, 202);
    }
    if (method !== "GET") return methodNotAllowed("GET");
    const session = await brain.getSession(sessionId);
    return session ? json(session) : error(404, "session_not_found");
  }

  return error(404, "not_found");
}

async function deleteAccount(userId: string, brain: Brain, env: Env): Promise<Response> {
  if (!env.WORKOS_API_KEY) return error(503, "account_deletion_unavailable");
  await brain.wipe();
  if (!(await deleteWorkosUser(userId, env.WORKOS_API_KEY))) return error(502, "account_deletion_failed");
  return new Response(null, { status: 204 });
}

function methodNotAllowed(allow: string): Response {
  return error(405, "method_not_allowed", undefined, { Allow: allow });
}
