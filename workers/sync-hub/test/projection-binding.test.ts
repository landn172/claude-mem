/**
 * Same-account limitation: a Worker cannot fetch another Worker's
 * *.workers.dev URL in its own zone — the subrequest never routes to the
 * target Worker (observed as projection_upstream_404 on a live personal
 * deployment). The fix: when a PROJECTOR service binding is configured,
 * drainProjection must send projection pages through the binding instead of
 * global fetch. The dependencies.fetchImpl test seam keeps priority so the
 * existing projection test matrix is untouched.
 */

import { describe, expect, it } from "vitest";
import { drainProjection } from "../src/index";

interface StubCalls {
	bindingRequests: Request[];
	heartbeats: number;
	advanced: string[];
	released: number;
}

function makeEnv(calls: StubCalls, withBinding: boolean): Env {
	let projectedSeq = "0";
	const stub = {
		async getProjectionState() {
			return { protocol_version: 1, epoch: "5", head_seq: "1", projected_seq: projectedSeq };
		},
		async acquireProjectionLease() {
			return { acquired: true, lease_token: "lease-1" };
		},
		async getProjectionPage() {
			return {
				protocol_version: 1,
				epoch: "5",
				from_seq_exclusive: "0",
				through_seq: "1",
				target_seq: "1",
				ops: [{ seq: "1", body: "{}", operation_sha256: "x".repeat(43) }],
			};
		},
		async heartbeatProjectionLease() {
			calls.heartbeats += 1;
		},
		async advanceProjectionCheckpoint(_token: string, epoch: string, _from: string, through: string) {
			calls.advanced.push(`${epoch}:${through}`);
			projectedSeq = through;
			return { protocol_version: 1, epoch, head_seq: "1", projected_seq: through };
		},
		async releaseProjectionLease() {
			calls.released += 1;
		},
	};
	const projector = {
		async fetch(input: RequestInfo | URL, init?: RequestInit) {
			const request = new Request(input, init);
			calls.bindingRequests.push(request);
			const body = (await request.json()) as { epoch: string; through_seq: string };
			return Response.json({
				protocol_version: 1,
				epoch: body.epoch,
				projected_through_seq: body.through_seq,
			});
		},
	};
	return {
		INTERNAL_PROJECTOR_URL: "https://cmem-self-host.example.workers.dev/internal/project",
		CMEM_INTERNAL_PROJECTOR_SECRET: "projector-secret",
		SYNC_HUB: { getByName: () => stub },
		...(withBinding ? { PROJECTOR: projector } : {}),
	} as unknown as Env;
}

describe("projection service binding", () => {
	it("routes projection pages through env.PROJECTOR when the binding exists", async () => {
		const calls: StubCalls = { bindingRequests: [], heartbeats: 0, advanced: [], released: 0 };
		const result = await drainProjection(makeEnv(calls, true), "user-1", "1");
		expect(result.ok).toBe(true);
		expect(result.projectedSeq).toBe("1");
		expect(calls.bindingRequests.length).toBe(1);
		const sent = calls.bindingRequests[0];
		expect(sent.url).toBe("https://cmem-self-host.example.workers.dev/internal/project");
		expect(sent.headers.get("Authorization")).toBe("Bearer projector-secret");
		expect(calls.advanced).toEqual(["5:1"]);
	});

	it("keeps the dependencies.fetchImpl seam ahead of the binding", async () => {
		const calls: StubCalls = { bindingRequests: [], heartbeats: 0, advanced: [], released: 0 };
		let seamCalls = 0;
		const result = await drainProjection(makeEnv(calls, true), "user-1", "1", {
			fetchImpl: async (_input, init) => {
				seamCalls += 1;
				const body = JSON.parse(String(init?.body)) as { epoch: string; through_seq: string };
				return Response.json({
					protocol_version: 1,
					epoch: body.epoch,
					projected_through_seq: body.through_seq,
				});
			},
		});
		expect(result.ok).toBe(true);
		expect(seamCalls).toBe(1);
		expect(calls.bindingRequests.length).toBe(0);
	});
});
