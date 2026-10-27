/**
 * Worker bindings. MEMDB comes from wrangler.jsonc; the secrets are set via
 * `wrangler secret put` and typed here (same convention as
 * workers/sync-hub/src/secrets.d.ts — a committed var would shadow the
 * secret at deploy time).
 */
interface Env {
	/** Must equal the sync hub's CMEM_INTERNAL_PROJECTOR_SECRET. */
	CMEM_INTERNAL_PROJECTOR_SECRET?: string;
	/** Remote MCP credential (bearer header or /u/<token>/mcp path form). */
	MCP_TOKEN?: string;
}
