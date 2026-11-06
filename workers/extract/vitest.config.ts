import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// A stand-in for the brain Worker (sous-brain), so the USER_BRAIN binding resolves in tests
// and we can check recipes land in the right user's brain.
const fakeBrain = `
import { DurableObject } from "cloudflare:workers";
export class UserBrain extends DurableObject {
  async createRecipe(recipe) {
    const recipes = (await this.ctx.storage.get("recipes")) ?? [];
    const saved = { ...recipe, id: crypto.randomUUID(), slug: "fake", created_at: new Date().toISOString(), updated_at: new Date().toISOString() };
    recipes.push(saved);
    await this.ctx.storage.put("recipes", recipes);
    return saved;
  }
  async listRecipes() {
    return (await this.ctx.storage.get("recipes")) ?? [];
  }
}
export default { fetch: () => new Response("fake brain") };
`;

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: { ANTHROPIC_API_KEY: "fake-anthropic-api-key" },
        workers: [{ name: "sous-brain", modules: true, script: fakeBrain, compatibilityDate: "2026-11-04", durableObjects: { USER_BRAIN: "UserBrain" } }],
      },
    }),
  ],
});
