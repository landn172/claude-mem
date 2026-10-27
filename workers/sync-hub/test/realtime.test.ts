/// <reference types="@cloudflare/vitest-pool-workers/types" />
import { env, evictDurableObject, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { PushOutcome, PushResult } from "../src/do/SyncHub";
import { KILL_SWITCH_KEY } from "../src/kill-switch";
import { mintRealtimeToken, nowSeconds, verifyRealtimeToken } from "../src/realtime";
import { observationOp } from "./content-v2-helpers";

const base = "https://sync-hub.test";
/** Secrets are declared on the Worker Env, not on the cloudflare:test env type. */
const secret = (env as { CMEM_INTERNAL_PROJECTOR_SECRET?: string }).CMEM_INTERNAL_PROJECTOR_SECRET ?? "";

interface Grant {
	access_token: string;
	expires_at: number;
	realtime_url: string;
	apikey: string;
	topic: string;
}

interface Frame {
	topic: string;
	event: string;
	payload: Record<string, unknown>;
	ref: string | null;
	join_ref?: string | null;
}

function headers(userId: string, deviceId: string): Record<string, string> {
	return {
		Authorization: `Bearer valid-for:${userId}`,
		"X-User-Id": userId,
		"X-Device-Id": deviceId,
	};
}

function ok(outcome: PushOutcome): PushResult {
	if ("refused" in outcome) throw new Error(`unexpected refusal: ${outcome.error}`);
	return outcome;
}

async function grant(userId: string, deviceId: string): Promise<Grant> {
	const response = await SELF.fetch(`${base}/v1/sync/realtime-token`, {
		method: "POST",
		headers: headers(userId, deviceId),
	});
	expect(response.status).toBe(200);
	return response.json();
}

interface Socket {
	ws: WebSocket;
	frames: Frame[];
	send(frame: Record<string, unknown>): void;
}

async function open(apikey: string): Promise<Socket> {
	const response = await SELF.fetch(`${base}/v1/sync/realtime?apikey=${encodeURIComponent(apikey)}&vsn=1.0.0`, {
		headers: { Upgrade: "websocket" },
	});
	expect(response.status).toBe(101);
	const ws = response.webSocket!;
	const frames: Frame[] = [];
	ws.accept();
	ws.addEventListener("message", (event) => {
		frames.push(JSON.parse(String(event.data)) as Frame);
	});
	return { ws, frames, send: (frame) => ws.send(JSON.stringify(frame)) };
}

async function join(userId: string, deviceId: string): Promise<Socket & { topic: string }> {
	const credentials = await grant(userId, deviceId);
	const socket = await open(credentials.apikey);
	const topic = `realtime:${credentials.topic}`;
	socket.send({
		topic,
		event: "phx_join",
		payload: { config: { private: true }, access_token: credentials.access_token },
		ref: "1",
		join_ref: "1",
	});
	await waitFor(() => replyTo(socket, "1") !== undefined, "join reply");
	expect(replyTo(socket, "1")?.payload.status).toBe("ok");
	return { ...socket, topic };
}

function replyTo(socket: Socket, ref: string): Frame | undefined {
	return socket.frames.find((frame) => frame.event === "phx_reply" && frame.ref === ref);
}

function broadcasts(socket: Socket): Frame[] {
	return socket.frames.filter((frame) => frame.event === "broadcast");
}

async function waitFor(condition: () => boolean, what: string): Promise<void> {
	const deadline = Date.now() + 5_000;
	while (Date.now() < deadline) {
		if (condition()) return;
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
	throw new Error(`timed out waiting for ${what}`);
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 100));

describe("realtime token", () => {
	it("mints a grant in the shape 13.37 clients validate", async () => {
		const credentials = await grant("user-rt-grant", "dev-a");
		expect(credentials.realtime_url).toBe("wss://sync-hub.test/v1/sync/realtime");
		expect(credentials.topic).toBe("sync-hub:user-rt-grant");
		expect(credentials.apikey).toBe(credentials.access_token);
		expect(credentials.expires_at).toBeGreaterThan(nowSeconds() + 3_000);
		const claims = await verifyRealtimeToken(secret, credentials.access_token, nowSeconds());
		expect(claims).toEqual({ userId: "user-rt-grant", deviceId: "dev-a", expiresAt: credentials.expires_at });
	});

	it("requires hub auth, POST, and a device id", async () => {
		expect((await SELF.fetch(`${base}/v1/sync/realtime-token`, { method: "POST" })).status).toBe(401);
		expect((await SELF.fetch(`${base}/v1/sync/realtime-token`, { headers: headers("user-rt-405", "dev-a") })).status)
			.toBe(405);
		const { "X-Device-Id": _omitted, ...noDevice } = headers("user-rt-400", "dev-a");
		expect((await SELF.fetch(`${base}/v1/sync/realtime-token`, { method: "POST", headers: noDevice })).status)
			.toBe(400);
	});

	it("rejects tampered, expired, and foreign-secret tokens", async () => {
		const token = await mintRealtimeToken(secret, { userId: "u", deviceId: "d", expiresAt: nowSeconds() + 60 });
		const [body, signature] = token.split(".");
		expect(await verifyRealtimeToken(secret, `${body}x.${signature}`, nowSeconds())).toBeNull();
		expect(await verifyRealtimeToken("another-secret", token, nowSeconds())).toBeNull();
		expect(await verifyRealtimeToken(secret, token, nowSeconds() + 61)).toBeNull();
		expect(await verifyRealtimeToken(secret, "not-a-token", nowSeconds())).toBeNull();
	});
});

describe("phoenix socket", () => {
	it("refuses upgrades without a valid apikey or Upgrade header", async () => {
		const missing = await SELF.fetch(`${base}/v1/sync/realtime`, { headers: { Upgrade: "websocket" } });
		expect(missing.status).toBe(401);
		const forged = await SELF.fetch(`${base}/v1/sync/realtime?apikey=abc.def`, { headers: { Upgrade: "websocket" } });
		expect(forged.status).toBe(401);
		const credentials = await grant("user-rt-426", "dev-a");
		const plain = await SELF.fetch(`${base}/v1/sync/realtime?apikey=${credentials.apikey}`);
		expect(plain.status).toBe(426);
	});

	it("answers heartbeats, token refreshes, and refuses bad joins", async () => {
		const user = "user-rt-protocol";
		const socket = await join(user, "dev-a");
		socket.send({ topic: "phoenix", event: "heartbeat", payload: {}, ref: "2" });
		await waitFor(() => replyTo(socket, "2") !== undefined, "heartbeat reply");
		expect(replyTo(socket, "2")).toMatchObject({ topic: "phoenix", payload: { status: "ok" } });

		const refreshed = await grant(user, "dev-a");
		socket.send({ topic: socket.topic, event: "access_token", payload: { access_token: refreshed.access_token }, ref: "3", join_ref: "1" });
		await waitFor(() => replyTo(socket, "3") !== undefined, "refresh reply");
		expect(replyTo(socket, "3")?.payload.status).toBe("ok");

		const foreign = await grant("user-rt-other", "dev-a");
		socket.send({ topic: socket.topic, event: "access_token", payload: { access_token: foreign.access_token }, ref: "4" });
		await waitFor(() => replyTo(socket, "4") !== undefined, "foreign refresh reply");
		expect(replyTo(socket, "4")?.payload.status).toBe("error");

		socket.send({ topic: "realtime:sync-hub:someone-else", event: "phx_join", payload: {}, ref: "5" });
		await waitFor(() => replyTo(socket, "5") !== undefined, "foreign topic reply");
		expect(replyTo(socket, "5")?.payload.status).toBe("error");
		socket.ws.close();
	});

	it("broadcasts advance to joined replicas only, excluding the origin device", async () => {
		const user = "user-rt-fanout";
		const origin = await join(user, "dev-a");
		const replica = await join(user, "dev-b");
		const unjoined = await open((await grant(user, "dev-c")).apikey);
		const result = ok(await env.SYNC_HUB.getByName(user).pushOps("dev-a", [await observationOp("1")]));
		await waitFor(() => broadcasts(replica).length === 1, "advance broadcast");
		const status = await (await SELF.fetch(`${base}/v1/sync/status`, { headers: headers(user, "dev-b") })).json() as {
			epoch: string;
		};
		expect(broadcasts(replica)[0]).toEqual({
			topic: replica.topic,
			event: "broadcast",
			payload: { type: "broadcast", event: "advance", payload: { epoch: status.epoch, head_seq: result.head_seq } },
			ref: null,
		});
		await settle();
		expect(broadcasts(origin)).toHaveLength(0);
		expect(unjoined.frames).toHaveLength(0);
		for (const socket of [origin, replica, unjoined]) socket.ws.close();
	});

	it("keeps a joined channel across hibernation", async () => {
		const user = "user-rt-hibernate";
		const replica = await join(user, "dev-b");
		const stub = env.SYNC_HUB.getByName(user);
		await evictDurableObject(stub, { webSockets: "hibernate" });
		replica.send({ topic: "phoenix", event: "heartbeat", payload: {}, ref: "9" });
		await waitFor(() => replyTo(replica, "9") !== undefined, "post-hibernation heartbeat reply");
		ok(await stub.pushOps("dev-a", [await observationOp("1")]));
		await waitFor(() => broadcasts(replica).length === 1, "post-hibernation advance");
		replica.ws.close();
	});

	it("tells a channel whose token lapsed to reconnect instead of broadcasting", async () => {
		const user = "user-rt-expired";
		const token = await mintRealtimeToken(secret, {
			userId: user,
			deviceId: "dev-b",
			expiresAt: nowSeconds() + 2,
		});
		const socket = await open(token);
		const topic = `realtime:sync-hub:${user}`;
		socket.send({ topic, event: "phx_join", payload: { access_token: token }, ref: "1", join_ref: "1" });
		await waitFor(() => replyTo(socket, "1") !== undefined, "join reply");
		await new Promise((resolve) => setTimeout(resolve, 2_100));
		ok(await env.SYNC_HUB.getByName(user).pushOps("dev-a", [await observationOp("1")]));
		await waitFor(() => socket.frames.some((frame) => frame.event === "system"), "system error");
		expect(socket.frames.find((frame) => frame.event === "system")?.payload.status).toBe("error");
		expect(broadcasts(socket)).toHaveLength(0);
	});
});

describe("kill switch", () => {
	it("refuses realtime tokens and upgrades in poll mode", async () => {
		const credentials = await grant("user-rt-kill", "dev-a");
		await env.AUTH_CACHE.put(KILL_SWITCH_KEY, "1");
		try {
			const token = await SELF.fetch(`${base}/v1/sync/realtime-token`, {
				method: "POST",
				headers: headers("user-rt-kill", "dev-a"),
			});
			expect(token.status).toBe(503);
			expect(token.headers.get("X-Sync-Mode")).toBe("poll");
			const upgrade = await SELF.fetch(`${base}/v1/sync/realtime?apikey=${credentials.apikey}`, {
				headers: { Upgrade: "websocket" },
			});
			expect(upgrade.status).toBe(503);
		} finally {
			await env.AUTH_CACHE.delete(KILL_SWITCH_KEY);
		}
		(await open(credentials.apikey)).ws.close();
	});
});
