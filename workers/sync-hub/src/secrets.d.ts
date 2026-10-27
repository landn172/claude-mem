/**
 * Secret bindings — set via `wrangler secret put` (DEPLOY.md), deliberately
 * NOT declared in wrangler.jsonc vars: a var and a secret share one
 * namespace, and a committed var would shadow (or conflict with) the secret
 * at deploy time. `wrangler types` only generates config-declared bindings,
 * so the secrets are typed here via global interface merging with the
 * generated `Env` (worker-configuration.d.ts). Optional on purpose: the
 * watchdog treats absence as "unconfigured": it logs loudly, Discord-pages
 * when the webhook secret is set, and never fabricates a metrics breach.
 */
interface Env {
	/**
	 * When set (non-empty), the Worker proxies every request — including
	 * WebSocket upgrades — to this origin and touches zero DO and zero KV.
	 * Empty / unset keeps today's Durable Object + KV path.
	 */
	FORWARD_ORIGIN?: string;
	/** Shared Hub/Pro internal projector and payload-free metadata credential. */
	CMEM_INTERNAL_PROJECTOR_SECRET?: string;
	/**
	 * Self-host auth (wrangler.personal.jsonc): "static" replaces the
	 * TOKEN_VERIFY_URL/KV path with a constant-time compare against the two
	 * bindings below. Unset or any other value ⇒ the default verify path.
	 * AUTH_MODE and SYNC_STATIC_USER_ID are vars in the personal config only
	 * (absent from wrangler.jsonc, hence typed here, not generated);
	 * SYNC_STATIC_TOKEN is a secret: `wrangler secret put SYNC_STATIC_TOKEN
	 * -c wrangler.personal.local.jsonc` (the gitignored copy of the template).
	 */
	AUTH_MODE?: string;
	SYNC_STATIC_USER_ID?: string;
	SYNC_STATIC_TOKEN?: string;
	/**
	 * Self-host only (wrangler.personal.jsonc `services`): service binding to
	 * the companion projector Worker. Same-zone workers.dev fetches do not
	 * route Worker-to-Worker, so projection pages go through this binding
	 * when it exists; absent (cmem.ai deployment) global fetch is used.
	 */
	PROJECTOR?: Fetcher;
	/**
	 * Cloudflare API token for the GraphQL Analytics API.
	 * Scope: Account → Account Analytics → Read.
	 * `wrangler secret put ANALYTICS_API_TOKEN`
	 */
	ANALYTICS_API_TOKEN?: string;
	/**
	 * Discord webhook URL for watchdog alerts (runtime credential lives in
	 * ~/Scripts/claude-mem/.env as DISCORD_UPDATES_WEBHOOK — NEVER hardcode
	 * or commit a webhook URL).
	 * `wrangler secret put DISCORD_WEBHOOK_URL`
	 */
	DISCORD_WEBHOOK_URL?: string;
}
