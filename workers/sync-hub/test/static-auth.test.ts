/**
 * Static auth mode (AUTH_MODE=static) — the self-host path. One shared token
 * and one canonical user id come from the deployment's own bindings, so
 * authentication must complete with NO outbound verify fetch and NO KV
 * traffic. These tests call authenticateRequest directly (like the
 * token-verdict cache suite) because the mode is an env binding: flipping it
 * globally in vitest.config.ts would silently drain the real verify-path
 * suites of their subject.
 *
 * The dependency stubs RECORD instead of throwing so a violation surfaces as
 * an assertion on `calls`, not as an incidental exception with a misleading
 * stack.
 */

import { describe, expect, it } from "vitest";
import {
	authenticateRequest,
	type AuthDependencies,
} from "../src/index";

const base = "https://sync-hub-personal.example.workers.dev";
const configuredUserId = "11111111-1111-4111-8111-111111111111";
const configuredToken = "a-static-token-of-respectable-length";

function staticEnv(overrides: Record<string, string | undefined> = {}): Env {
	return {
		AUTH_MODE: "static",
		SYNC_STATIC_USER_ID: configuredUserId,
		SYNC_STATIC_TOKEN: configuredToken,
		// Deliberately empty: static mode must never consult a verify endpoint.
		TOKEN_VERIFY_URL: "",
		AUTH_CACHE_TTL_SECONDS: "60",
		...overrides,
	} as unknown as Env;
}

function request(token: string, userId: string): Request {
	return new Request(`${base}/v1/sync/status`, {
		headers: {
			Authorization: `Bearer ${token}`,
			"X-User-Id": userId,
			"X-Device-Id": "dev-static",
		},
	});
}

/** Records every dependency touch; static mode must leave `calls` empty. */
function recordingDependencies(calls: string[]): AuthDependencies {
	return {
		async readCachedVerdict() {
			calls.push("kv:get");
			return null;
		},
		async cacheVerifiedVerdict() {
			calls.push("kv:put");
		},
		async verifyToken() {
			calls.push("fetch:verify");
			return new Response("static mode must not reach a verify endpoint", {
				status: 500,
			});
		},
		logCacheFailure(operation) {
			calls.push(`log:${operation}`);
		},
	};
}

describe("static auth mode", () => {
	it("authenticates the configured token/user pair with no KV and no outbound fetch", async () => {
		const calls: string[] = [];
		const result = await authenticateRequest(
			request(configuredToken, configuredUserId),
			staticEnv(),
			recordingDependencies(calls),
		);
		expect(result).toEqual({
			ok: true,
			userId: configuredUserId,
			deviceId: "dev-static",
			deviceName: null,
		});
		expect(calls).toEqual([]);
	});

	it("401s a wrong token without touching KV or the verify endpoint", async () => {
		const calls: string[] = [];
		const result = await authenticateRequest(
			request("not-the-configured-token", configuredUserId),
			staticEnv(),
			recordingDependencies(calls),
		);
		expect(result.ok).toBe(false);
		if (result.ok) throw new Error("wrong token unexpectedly authenticated");
		expect(result.response.status).toBe(401);
		expect(calls).toEqual([]);
	});

	it("401s a token that is a prefix of the configured token (length must matter)", async () => {
		const calls: string[] = [];
		const result = await authenticateRequest(
			request(configuredToken.slice(0, -1), configuredUserId),
			staticEnv(),
			recordingDependencies(calls),
		);
		expect(result.ok).toBe(false);
		if (result.ok) throw new Error("prefix token unexpectedly authenticated");
		expect(result.response.status).toBe(401);
		expect(calls).toEqual([]);
	});

	it("403s a valid token presented with a foreign X-User-Id (canonical binding holds)", async () => {
		const calls: string[] = [];
		const result = await authenticateRequest(
			request(configuredToken, "22222222-2222-4222-8222-222222222222"),
			staticEnv(),
			recordingDependencies(calls),
		);
		expect(result.ok).toBe(false);
		if (result.ok) throw new Error("foreign user id unexpectedly authenticated");
		expect(result.response.status).toBe(403);
		expect(calls).toEqual([]);
	});

	it("503s fail-closed when SYNC_STATIC_TOKEN is missing", async () => {
		const calls: string[] = [];
		const result = await authenticateRequest(
			request(configuredToken, configuredUserId),
			staticEnv({ SYNC_STATIC_TOKEN: undefined }),
			recordingDependencies(calls),
		);
		expect(result.ok).toBe(false);
		if (result.ok) throw new Error("unconfigured static mode unexpectedly authenticated");
		expect(result.response.status).toBe(503);
		expect(calls).toEqual([]);
	});

	it("503s fail-closed when SYNC_STATIC_USER_ID is missing", async () => {
		const calls: string[] = [];
		const result = await authenticateRequest(
			request(configuredToken, configuredUserId),
			staticEnv({ SYNC_STATIC_USER_ID: "" }),
			recordingDependencies(calls),
		);
		expect(result.ok).toBe(false);
		if (result.ok) throw new Error("unconfigured static mode unexpectedly authenticated");
		expect(result.response.status).toBe(503);
		expect(calls).toEqual([]);
	});

	it("still 401s a missing bearer token before consulting static config", async () => {
		const calls: string[] = [];
		const result = await authenticateRequest(
			new Request(`${base}/v1/sync/status`, {
				headers: { "X-User-Id": configuredUserId, "X-Device-Id": "dev-static" },
			}),
			staticEnv(),
			recordingDependencies(calls),
		);
		expect(result.ok).toBe(false);
		if (result.ok) throw new Error("missing bearer unexpectedly authenticated");
		expect(result.response.status).toBe(401);
		expect(calls).toEqual([]);
	});

	it("leaves the verify path in charge when AUTH_MODE is unset (regression guard)", async () => {
		const calls: string[] = [];
		const dependencies: AuthDependencies = {
			...recordingDependencies(calls),
			async verifyToken() {
				calls.push("fetch:verify");
				return Response.json({ userId: configuredUserId });
			},
		};
		const result = await authenticateRequest(
			request(configuredToken, configuredUserId),
			staticEnv({ AUTH_MODE: undefined, TOKEN_VERIFY_URL: "https://cmem.ai/api/pro/sync/verify" }),
			dependencies,
		);
		expect(result).toEqual({
			ok: true,
			userId: configuredUserId,
			deviceId: "dev-static",
			deviceName: null,
		});
		expect(calls).toContain("fetch:verify");
	});

	it("treats an unknown AUTH_MODE value as the default verify path, not as static", async () => {
		const calls: string[] = [];
		const dependencies: AuthDependencies = {
			...recordingDependencies(calls),
			async verifyToken() {
				calls.push("fetch:verify");
				return Response.json({ userId: configuredUserId });
			},
		};
		const result = await authenticateRequest(
			request(configuredToken, configuredUserId),
			staticEnv({ AUTH_MODE: "Static", TOKEN_VERIFY_URL: "https://cmem.ai/api/pro/sync/verify" }),
			dependencies,
		);
		expect(result.ok).toBe(true);
		expect(calls).toContain("fetch:verify");
	});
});
