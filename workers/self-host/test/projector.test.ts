/**
 * The projection endpoint the sync hub REQUIRES. Contract under test
 * (workers/sync-hub/src/index.ts drainProjection + projection-protocol.ts):
 *
 *   - the response must echo {protocol_version:1, epoch, projected_through_seq:
 *     through_seq} EXACTLY, or the hub treats the page as failed and retries;
 *   - pages are replayed at-least-once, so application must be idempotent
 *     (entity_rev guard);
 *   - one malformed op must never wedge the checkpoint: record, skip, 200.
 */

import { env, SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import {
	contentOp,
	mutationOp,
	observationPayload,
	poisonOp,
	projectionBody,
	projectRequest,
	promptPayload,
	tombstoneOp,
} from "./fixtures";
import { stableDocumentId } from "../../sync-hub/src/canonical-content";

async function post(body: string, secret?: string): Promise<Response> {
	return SELF.fetch(projectRequest(body, secret));
}

async function observationRow(entityId: string): Promise<Record<string, unknown> | null> {
	return env.MEMDB
		.prepare("SELECT * FROM observations WHERE entity_id = ?")
		.bind(entityId)
		.first();
}

describe("projector auth", () => {
	it("401s a missing bearer", async () => {
		const body = projectionBody({ ops: [await contentOp({ seq: "1", kind: "observation", localId: "1" })] });
		const res = await SELF.fetch("https://cmem-self-host.example.workers.dev/internal/project", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body,
		});
		expect(res.status).toBe(401);
	});

	it("401s a wrong secret", async () => {
		const body = projectionBody({ ops: [await contentOp({ seq: "1", kind: "observation", localId: "1" })] });
		const res = await post(body, "not-the-secret");
		expect(res.status).toBe(401);
	});
});

describe("projector envelope validation", () => {
	it("400s a non-JSON body", async () => {
		const res = await post("this is not json");
		expect(res.status).toBe(400);
	});

	it("400s a wrong protocol_version", async () => {
		const op = await contentOp({ seq: "1", kind: "observation", localId: "1" });
		const body = JSON.parse(projectionBody({ ops: [op] })) as Record<string, unknown>;
		body.protocol_version = 2;
		const res = await post(JSON.stringify(body));
		expect(res.status).toBe(400);
	});
});

describe("content op application", () => {
	it("applies an observation and echoes the checkpoint exactly", async () => {
		const op = await contentOp({ seq: "10", kind: "observation", localId: "100" });
		const res = await post(projectionBody({ ops: [op], epoch: "7", throughSeq: "10" }));
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({
			protocol_version: 1,
			epoch: "7",
			projected_through_seq: "10",
		});

		const entityId = await stableDocumentId("observation", "test-device-1", "100");
		const row = await observationRow(entityId);
		expect(row).not.toBeNull();
		expect(row?.project).toBe("proj-a");
		expect(row?.title).toBe("Fixed the flux capacitor");
		expect(row?.memory_session_id).toBe("sess-1");
	});

	it("is idempotent when the hub replays the same page", async () => {
		const op = await contentOp({ seq: "11", kind: "observation", localId: "101" });
		const body = projectionBody({ ops: [op], throughSeq: "11" });
		expect((await post(body)).status).toBe(200);
		expect((await post(body)).status).toBe(200);

		const entityId = await stableDocumentId("observation", "test-device-1", "101");
		const count = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM observations WHERE entity_id = ?")
			.bind(entityId)
			.first<{ n: number }>();
		expect(count?.n).toBe(1);
	});

	it("a higher entity_rev replaces the payload; a stale one is skipped", async () => {
		const entityId = await stableDocumentId("observation", "test-device-1", "102");
		const v1 = await contentOp({
			seq: "12", kind: "observation", localId: "102",
			rev: "1", payload: observationPayload({ title: "v1 title" }),
		});
		const v3 = await contentOp({
			seq: "13", kind: "observation", localId: "102",
			rev: "3", payload: observationPayload({ title: "v3 title" }),
		});
		const v2stale = await contentOp({
			seq: "14", kind: "observation", localId: "102",
			rev: "2", payload: observationPayload({ title: "v2 stale title" }),
		});
		expect((await post(projectionBody({ ops: [v1], throughSeq: "12" }))).status).toBe(200);
		expect((await post(projectionBody({ ops: [v3], fromSeqExclusive: "12", throughSeq: "13" }))).status).toBe(200);
		expect((await post(projectionBody({ ops: [v2stale], fromSeqExclusive: "13", throughSeq: "14" }))).status).toBe(200);

		const row = await observationRow(entityId);
		expect(row?.title).toBe("v3 title");
	});

	it("a tombstone removes the row and its FTS entry", async () => {
		const live = await contentOp({
			seq: "15", kind: "observation", localId: "103",
			payload: observationPayload({ title: "doomed unicorn observation" }),
		});
		expect((await post(projectionBody({ ops: [live], throughSeq: "15" }))).status).toBe(200);
		const hitsBefore = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM observations_fts WHERE observations_fts MATCH 'unicorn'")
			.first<{ n: number }>();
		expect(hitsBefore?.n).toBe(1);

		const gone = await tombstoneOp({ seq: "16", kind: "observation", localId: "103", rev: "2" });
		expect((await post(projectionBody({ ops: [gone], fromSeqExclusive: "15", throughSeq: "16" }))).status).toBe(200);

		const entityId = await stableDocumentId("observation", "test-device-1", "103");
		expect(await observationRow(entityId)).toBeNull();
		const hitsAfter = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM observations_fts WHERE observations_fts MATCH 'unicorn'")
			.first<{ n: number }>();
		expect(hitsAfter?.n).toBe(0);
	});

	it("summaries and prompts land in their own tables", async () => {
		const ops = [
			await contentOp({ seq: "17", kind: "summary", localId: "200" }),
			await contentOp({ seq: "18", kind: "prompt", localId: "300" }),
		];
		expect((await post(projectionBody({ ops, throughSeq: "18" }))).status).toBe(200);

		const summary = await env.MEMDB
			.prepare("SELECT * FROM session_summaries WHERE memory_session_id = 'sess-1'")
			.first();
		expect(summary?.request).toBe("fix the capacitor");
		const prompt = await env.MEMDB
			.prepare("SELECT * FROM user_prompts WHERE content_session_id = 'content-sess-1'")
			.first();
		expect(prompt?.prompt_text).toBe("please fix the flux capacitor");
	});

	it("FTS reflects payload updates (no stale index entries)", async () => {
		const v1 = await contentOp({
			seq: "19", kind: "observation", localId: "104",
			rev: "1", payload: observationPayload({ narrative: "the walrus narrative" }),
		});
		const v2 = await contentOp({
			seq: "20", kind: "observation", localId: "104",
			rev: "2", payload: observationPayload({ narrative: "the pelican narrative" }),
		});
		expect((await post(projectionBody({ ops: [v1], throughSeq: "19" }))).status).toBe(200);
		expect((await post(projectionBody({ ops: [v2], fromSeqExclusive: "19", throughSeq: "20" }))).status).toBe(200);

		const walrus = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM observations_fts WHERE observations_fts MATCH 'walrus'")
			.first<{ n: number }>();
		expect(walrus?.n).toBe(0);
		const pelican = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM observations_fts WHERE observations_fts MATCH 'pelican'")
			.first<{ n: number }>();
		expect(pelican?.n).toBe(1);
	});
});

describe("mutation op application", () => {
	it("set_title parks a custom title for the session", async () => {
		const op = await mutationOp({
			seq: "30",
			uuid: "11111111-1111-4111-8111-111111111111",
			mutation: {
				op: "set_title",
				target: { memory_session_id: "sess-1" },
				fields: { custom_title: "The Flux Saga" },
			},
		});
		expect((await post(projectionBody({ ops: [op], throughSeq: "30" }))).status).toBe(200);
		const row = await env.MEMDB
			.prepare("SELECT custom_title FROM session_titles WHERE session_key = 'sess-1'")
			.first<{ custom_title: string }>();
		expect(row?.custom_title).toBe("The Flux Saga");
	});

	it("set_prompt_session repairs the targeted prompt row", async () => {
		const prompt = await contentOp({
			seq: "31", kind: "prompt", localId: "301",
			payload: promptPayload({ memory_session_id: "orphan", project: "proj-a" }),
		});
		const repair = await mutationOp({
			seq: "32",
			uuid: "22222222-2222-4222-8222-222222222222",
			mutation: {
				op: "set_prompt_session",
				target: { origin_device_id: "test-device-1", origin_local_id: "301" },
				fields: { memory_session_id: "sess-9", project: "proj-b" },
			},
		});
		expect((await post(projectionBody({ ops: [prompt, repair], throughSeq: "32" }))).status).toBe(200);

		const entityId = await stableDocumentId("prompt", "test-device-1", "301");
		const row = await env.MEMDB
			.prepare("SELECT memory_session_id, project FROM user_prompts WHERE entity_id = ?")
			.bind(entityId)
			.first<{ memory_session_id: string; project: string }>();
		expect(row?.memory_session_id).toBe("sess-9");
		expect(row?.project).toBe("proj-b");
	});

	it("remap_project renames matching rows across content tables", async () => {
		const ops = [
			await contentOp({
				seq: "33", kind: "observation", localId: "105",
				payload: observationPayload({ project: "old-proj" }),
			}),
			await contentOp({
				seq: "34", kind: "summary", localId: "201",
				payload: summaryPayloadWithProject("old-proj"),
			}),
			await mutationOp({
				seq: "35",
				uuid: "33333333-3333-4333-8333-333333333333",
				mutation: {
					op: "remap_project",
					where: { project: "old-proj" },
					fields: { project: "new-proj" },
				},
			}),
		];
		expect((await post(projectionBody({ ops, throughSeq: "35" }))).status).toBe(200);

		const obs = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM observations WHERE project = 'new-proj'")
			.first<{ n: number }>();
		expect(obs?.n).toBe(1);
		const sum = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM session_summaries WHERE project = 'new-proj'")
			.first<{ n: number }>();
		expect(sum?.n).toBe(1);
		const leftovers = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM observations WHERE project = 'old-proj'")
			.first<{ n: number }>();
		expect(leftovers?.n).toBe(0);
	});

	it("a replayed mutation applies once (entity guard on the mutation id)", async () => {
		const op = await mutationOp({
			seq: "36",
			uuid: "44444444-4444-4444-8444-444444444444",
			mutation: {
				op: "set_title",
				target: { memory_session_id: "sess-replay" },
				fields: { custom_title: "Replayed Title" },
			},
		});
		const body = projectionBody({ ops: [op], throughSeq: "36" });
		expect((await post(body)).status).toBe(200);
		expect((await post(body)).status).toBe(200);
		const rows = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM session_titles WHERE session_key = 'sess-replay'")
			.first<{ n: number }>();
		expect(rows?.n).toBe(1);
	});
});

describe("large pages", () => {
	it("applies a 60-entity page in order, honoring rev guards past any read-chunk boundary", async () => {
		// Pre-seed one entity (late in the page's entity order) at rev 3.
		const seeded = await contentOp({
			seq: "50", kind: "observation", localId: "700055",
			rev: "3", payload: observationPayload({ title: "seeded high rev" }),
		});
		expect((await post(projectionBody({ ops: [seeded], throughSeq: "50" }))).status).toBe(200);

		// One page: 60 distinct entities; entity 700055 arrives again at
		// STALE rev 1 in position 56 — far past a 50-entity read chunk.
		const ops = [];
		let seq = 100;
		for (let i = 0; i < 60; i++) {
			const localId = `${700000 + i}`;
			ops.push(await contentOp({
				seq: `${seq++}`, kind: "observation", localId,
				rev: "1",
				payload: observationPayload({ title: `bulk item ${i}` }),
			}));
		}
		const res = await post(projectionBody({ ops, throughSeq: `${seq - 1}` }));
		expect(res.status).toBe(200);

		const total = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM observations WHERE title LIKE 'bulk item %' OR title = 'seeded high rev'")
			.first<{ n: number }>();
		expect(total?.n).toBe(60);

		// The stale rev-1 op for the seeded entity must NOT have clobbered rev 3.
		const entityId = await stableDocumentId("observation", "test-device-1", "700055");
		const row = await observationRow(entityId);
		expect(row?.title).toBe("seeded high rev");
	});

	it("later rev wins when one entity appears twice in the same page", async () => {
		const first = await contentOp({
			seq: "200", kind: "observation", localId: "800001",
			rev: "1", payload: observationPayload({ title: "same-page v1" }),
		});
		const second = await contentOp({
			seq: "201", kind: "observation", localId: "800001",
			rev: "2", payload: observationPayload({ title: "same-page v2" }),
		});
		expect((await post(projectionBody({ ops: [first, second], throughSeq: "201" }))).status).toBe(200);
		const entityId = await stableDocumentId("observation", "test-device-1", "800001");
		const row = await observationRow(entityId);
		expect(row?.title).toBe("same-page v2");
	});
});

describe("poison ops", () => {
	it("records and skips a corrupt op, still answering the full checkpoint echo", async () => {
		const healthy = await contentOp({ seq: "40", kind: "observation", localId: "106" });
		const corrupt = await poisonOp("41");
		const res = await post(projectionBody({ ops: [healthy, corrupt], epoch: "9", throughSeq: "41" }));
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({
			protocol_version: 1,
			epoch: "9",
			projected_through_seq: "41",
		});

		const entityId = await stableDocumentId("observation", "test-device-1", "106");
		expect(await observationRow(entityId)).not.toBeNull();
		const skipped = await env.MEMDB
			.prepare("SELECT COUNT(*) AS n FROM skipped_ops WHERE seq = '41'")
			.first<{ n: number }>();
		expect(skipped?.n).toBe(1);
	});
});

function summaryPayloadWithProject(project: string): Record<string, unknown> {
	return {
		project,
		created_at: "2026-08-18T01:00:00.000Z",
		created_at_epoch: "1787003600000",
		memory_session_id: "sess-1",
		request: "fix the capacitor",
	};
}
