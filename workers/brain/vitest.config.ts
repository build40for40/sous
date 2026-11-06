import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: { bindings: { WORKOS_API_KEY: "fake-workos-api-key", ANTHROPIC_API_KEY: "fake-anthropic-api-key" } },
    }),
  ],
});
