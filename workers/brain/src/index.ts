import { BASE_PATH, error, HttpError, json, readJson } from "./http";
import { parseProfilePatch } from "./profile";
import { validateRecipe } from "./recipes";
import { authenticate, deleteWorkosUser } from "./workos";

import type { UserBrain } from "./brain";

export { UserBrain } from "./brain";

const MAX_BODY_BYTES = 256 * 1024;

// The generated stub types recurse too deeply on JSON preferences, so the stub is typed from the class directly.
type Rpc<T> = { [K in keyof T]: T[K] extends (...args: infer A) => infer R ? (...args: A) => Promise<Awaited<R>> : never };
type Brain = Rpc<Pick<UserBrain, "getProfile" | "updateProfile" | "wipe" | "listRecipes" | "getRecipe" | "createRecipe" | "deleteRecipe">>;

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

  const recipeId = path.match(/^\/recipes\/([^/]+)$/)?.[1];
  if (recipeId) {
    const id = decodeURIComponent(recipeId);
    if (method === "GET") {
      const recipe = await brain.getRecipe(id);
      return recipe ? json(recipe) : error(404, "recipe_not_found");
    }
    if (method === "DELETE") return (await brain.deleteRecipe(id)) ? new Response(null, { status: 204 }) : error(404, "recipe_not_found");
    return methodNotAllowed("GET, DELETE");
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
