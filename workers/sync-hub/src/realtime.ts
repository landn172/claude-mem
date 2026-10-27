/**
 * Live channel for claude-mem ≥13.37 clients, which speak the Supabase
 * Realtime (Phoenix vsn 1.0.0) protocol instead of the retired /v1/sync/ws
 * frames. POST /v1/sync/realtime-token mints a short-lived HMAC token; the
 * same token is the socket's `apikey` (a WebSocket cannot carry the hub's
 * auth headers) and the join's `access_token`. Frames are hints only: an
 * `advance` broadcast makes the client run its ordinary HTTP pull.
 */

export const REALTIME_PATH = "/v1/sync/realtime";
export const REALTIME_TOKEN_TTL_SECONDS = 3_600;
/** Keeps these signatures from ever validating as any other projector-secret MAC. */
const SIGNING_CONTEXT = "cmem-sync-realtime-v1.";
const MAX_TOKEN_LENGTH = 1_024;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

export interface RealtimeClaims {
	userId: string;
	deviceId: string;
	/** Unix seconds — the unit the client's `expires_at` expects. */
	expiresAt: number;
}

export interface PhoenixFrame {
	topic?: unknown;
	event?: unknown;
	payload?: unknown;
	ref?: unknown;
	join_ref?: unknown;
}

export function nowSeconds(): number {
	return Math.floor(Date.now() / 1000);
}

/** The client prefixes this with `realtime:` to form its channel topic. */
export function realtimeTopic(userId: string): string {
	return `sync-hub:${userId}`;
}

export function channelTopic(userId: string): string {
	return `realtime:${realtimeTopic(userId)}`;
}

/** Null disables the live channel; the token route then answers 404 so clients poll. */
export function realtimeSecret(env: Env): string | null {
	const secret = (env.CMEM_INTERNAL_PROJECTOR_SECRET ?? "").trim();
	return secret.length > 0 ? secret : null;
}

function base64UrlEncode(bytes: Uint8Array): string {
	let binary = "";
	for (const byte of bytes) binary += String.fromCharCode(byte);
	return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(text: string): Uint8Array | null {
	if (!/^[A-Za-z0-9_-]+$/.test(text)) return null;
	try {
		const binary = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((text.length + 3) % 4));
		return Uint8Array.from(binary, (char) => char.charCodeAt(0));
	} catch {
		return null;
	}
}

function signingKey(secret: string): Promise<CryptoKey> {
	return crypto.subtle.importKey(
		"raw",
		encoder.encode(secret),
		{ name: "HMAC", hash: "SHA-256" },
		false,
		["sign", "verify"],
	);
}

export async function mintRealtimeToken(secret: string, claims: RealtimeClaims): Promise<string> {
	const body = base64UrlEncode(
		encoder.encode(JSON.stringify({ u: claims.userId, d: claims.deviceId, e: claims.expiresAt })),
	);
	const signature = await crypto.subtle.sign(
		"HMAC",
		await signingKey(secret),
		encoder.encode(SIGNING_CONTEXT + body),
	);
	return `${body}.${base64UrlEncode(new Uint8Array(signature))}`;
}

/** Null for anything forged, malformed, or expired at `now` (Unix seconds). */
export async function verifyRealtimeToken(
	secret: string,
	token: string,
	now: number,
): Promise<RealtimeClaims | null> {
	if (token.length === 0 || token.length > MAX_TOKEN_LENGTH) return null;
	const parts = token.split(".");
	if (parts.length !== 2) return null;
	const [body, signaturePart] = parts;
	const signature = base64UrlDecode(signaturePart);
	if (signature === null) return null;
	const valid = await crypto.subtle.verify(
		"HMAC",
		await signingKey(secret),
		signature,
		encoder.encode(SIGNING_CONTEXT + body),
	);
	if (!valid) return null;
	const decoded = base64UrlDecode(body);
	if (decoded === null) return null;
	let claims: { u?: unknown; d?: unknown; e?: unknown };
	try {
		claims = JSON.parse(decoder.decode(decoded)) as typeof claims;
	} catch {
		return null;
	}
	if (
		typeof claims.u !== "string" || claims.u.length === 0
		|| typeof claims.d !== "string" || claims.d.length === 0
		|| typeof claims.e !== "number" || !Number.isFinite(claims.e)
	) {
		return null;
	}
	if (claims.e <= now) return null;
	return { userId: claims.u, deviceId: claims.d, expiresAt: claims.e };
}
