/**
 * Builders for REAL canonical wire ops — everything goes through the hub's
 * own wrapCanonicalBody/stableDocumentId, so a fixture that drifts from the
 * canonical contract fails in the builder, not as a false-negative test.
 */

import {
	type CanonicalContentBody,
	type CanonicalMutation,
	type ContentKind,
	canonicalJson,
	sha256Base64Url,
	stableDocumentId,
	wrapCanonicalBody,
} from "../../sync-hub/src/canonical-content";
import { serializeProjectionRequest } from "../../sync-hub/src/projection-protocol";

export const DEVICE_ID = "test-device-1";
export const USER_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
export const PROJECTOR_SECRET = "test-projector-secret";

export interface WireOp {
	seq: string;
	body: string;
	operation_sha256: string;
}

export function observationPayload(
	overrides: Record<string, unknown> = {},
): Record<string, unknown> {
	return {
		project: "proj-a",
		created_at: "2026-08-18T00:00:00.000Z",
		created_at_epoch: "1787000000000",
		memory_session_id: "sess-1",
		type: "bugfix",
		title: "Fixed the flux capacitor",
		subtitle: "it was the dilithium",
		text: "the capacitor fluxed when it should not",
		narrative: "We traced the flux to a loose dilithium coupling.",
		facts: ["coupling was loose"],
		concepts: ["how-it-works"],
		files_read: ["src/flux.ts"],
		files_modified: [],
		...overrides,
	};
}

export function summaryPayload(
	overrides: Record<string, unknown> = {},
): Record<string, unknown> {
	return {
		project: "proj-a",
		created_at: "2026-08-18T01:00:00.000Z",
		created_at_epoch: "1787003600000",
		memory_session_id: "sess-1",
		request: "fix the capacitor",
		learned: "couplings loosen",
		completed: "tightened it",
		...overrides,
	};
}

export function promptPayload(
	overrides: Record<string, unknown> = {},
): Record<string, unknown> {
	return {
		project: "proj-a",
		created_at: "2026-08-18T02:00:00.000Z",
		created_at_epoch: "1787007200000",
		content_session_id: "content-sess-1",
		memory_session_id: "sess-1",
		platform_source: "claude",
		prompt_text: "please fix the flux capacitor",
		...overrides,
	};
}

export async function contentOp(options: {
	seq: string;
	kind: ContentKind;
	localId: string;
	rev?: string;
	payload?: Record<string, unknown>;
	deviceId?: string;
}): Promise<WireOp> {
	const deviceId = options.deviceId ?? DEVICE_ID;
	const payload = options.payload
		?? (options.kind === "observation"
			? observationPayload()
			: options.kind === "summary" ? summaryPayload() : promptPayload());
	const body: CanonicalContentBody = {
		body_schema_version: 1,
		deleted: false,
		deleted_at: null,
		entity_rev: options.rev ?? "1",
		id: await stableDocumentId(options.kind, deviceId, options.localId),
		kind: options.kind,
		mutation: null,
		origin_device_id: deviceId,
		origin_local_id: options.localId,
		payload,
		payload_schema_version: 2,
		payload_sha256: await sha256Base64Url(canonicalJson(payload)),
	};
	const wrapped = await wrapCanonicalBody(body);
	return { seq: options.seq, ...wrapped };
}

export async function tombstoneOp(options: {
	seq: string;
	kind: ContentKind;
	localId: string;
	rev: string;
	deviceId?: string;
}): Promise<WireOp> {
	const deviceId = options.deviceId ?? DEVICE_ID;
	const body: CanonicalContentBody = {
		body_schema_version: 1,
		deleted: true,
		deleted_at: "2026-08-18T03:00:00.000Z",
		entity_rev: options.rev,
		id: await stableDocumentId(options.kind, deviceId, options.localId),
		kind: options.kind,
		mutation: null,
		origin_device_id: deviceId,
		origin_local_id: options.localId,
		payload: null,
		payload_schema_version: 2,
		payload_sha256: await sha256Base64Url("null"),
	};
	const wrapped = await wrapCanonicalBody(body);
	return { seq: options.seq, ...wrapped };
}

export async function mutationOp(options: {
	seq: string;
	uuid: string;
	mutation: CanonicalMutation;
}): Promise<WireOp> {
	const body: CanonicalContentBody = {
		body_schema_version: 1,
		deleted: false,
		deleted_at: null,
		entity_rev: "1",
		id: `mutation:${options.uuid}`,
		kind: "mutation",
		mutation: options.mutation,
		origin_device_id: DEVICE_ID,
		origin_local_id: null,
		payload: null,
		payload_schema_version: 2,
		payload_sha256: await sha256Base64Url("null"),
	};
	const wrapped = await wrapCanonicalBody(body);
	return { seq: options.seq, ...wrapped };
}

/** An op whose sha256 does not match its body — must be skipped, never 5xx. */
export async function poisonOp(seq: string): Promise<WireOp> {
	const healthy = await contentOp({ seq, kind: "observation", localId: "999" });
	return { ...healthy, body: `${healthy.body} ` };
}

export function projectionBody(options: {
	ops: readonly WireOp[];
	epoch?: string;
	fromSeqExclusive?: string;
	throughSeq?: string;
	userId?: string;
}): string {
	const ops = options.ops;
	return serializeProjectionRequest({
		userId: options.userId ?? USER_ID,
		epoch: options.epoch ?? "42",
		fromSeqExclusive: options.fromSeqExclusive ?? (ops.length > 0 ? decrement(ops[0].seq) : "0"),
		throughSeq: options.throughSeq ?? (ops.length > 0 ? ops[ops.length - 1].seq : "0"),
		ops,
	});
}

function decrement(seq: string): string {
	return (BigInt(seq) - 1n).toString(10);
}

export function projectRequest(body: string, secret: string = PROJECTOR_SECRET): Request {
	return new Request("https://cmem-self-host.example.workers.dev/internal/project", {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			Authorization: `Bearer ${secret}`,
		},
		body,
	});
}
