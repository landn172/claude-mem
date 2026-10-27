/**
 * Same @cloudflare/vitest-pool-workers Vite-plugin form as workers/sync-hub.
 * The D1 binding is supplied directly to miniflare (the committed
 * wrangler.jsonc carries a REPLACE_ME database id that only matters for real
 * deploys); the two secrets are plain test bindings.
 */

import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
	plugins: [
		cloudflareTest({
			main: "./src/index.ts",
			miniflare: {
				compatibilityDate: "2026-07-14",
				d1Databases: { MEMDB: "00000000-0000-4000-8000-000000000001" },
				bindings: {
					CMEM_INTERNAL_PROJECTOR_SECRET: "test-projector-secret",
					MCP_TOKEN: "test-mcp-token",
				},
			},
		}),
	],
});
