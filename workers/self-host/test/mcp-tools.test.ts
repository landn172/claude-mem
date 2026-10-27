/**
 * Remote MCP endpoint (Streamable HTTP, stateless JSON-RPC over POST).
 * Tool names and the index-first result contract hold parity with the local
 * MCP server (src/servers/mcp-server.ts): search → compact rows with numeric
 * ids, timeline → context around an anchor id, get_observations → full rows
 * for filtered ids. Data is seeded through the REAL projector endpoint so
 * these tests cover the projection → query pipeline end to end.
 */

import { env, SELF } from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";
import { contentOp, observationPayload, projectionBody, projectRequest, summaryPayload } from "./fixtures";

const base = "https://cmem-self-host.example.workers.dev";
const MCP_TOKEN = "test-mcp-token";

interface JsonRpcResponse {
	jsonrpc: "2.0";
	id: number;
	result?: Record<string, unknown>;
	error?: { code: number; message: string };
}

let nextId = 1;

async function rpc(
	message: Record<string, unknown>,
	options: { path?: string; token?: string | null } = {},
): Promise<Response> {
	const headers: Record<string, string> = {
		"Content-Type": "application/json",
		Accept: "application/json, text/event-stream",
	};
	if (options.token !== null) {
		headers.Authorization = `Bearer ${options.token ?? MCP_TOKEN}`;
	}
	return SELF.fetch(`${base}${options.path ?? "/mcp"}`, {
		method: "POST",
		headers,
		body: JSON.stringify(message),
	});
}

async function callTool(
	name: string,
	args: Record<string, unknown>,
): Promise<Record<string, unknown>> {
	const res = await rpc({
		jsonrpc: "2.0",
		id: nextId++,
		method: "tools/call",
		params: { name, arguments: args },
	});
	expect(res.status).toBe(200);
	const body = (await res.json()) as JsonRpcResponse;
	expect(body.error).toBeUndefined();
	const content = (body.result as { content: Array<{ type: string; text: string }> }).content;
	expect(content[0]?.type).toBe("text");
	return JSON.parse(content[0].text) as Record<string, unknown>;
}

/**
 * Distinct epochs, one project pair. Seeded once through the projector; the
 * unique project names keep these rows disjoint from other test files.
 */
beforeAll(async () => {
	const ops = [
		await contentOp({
			seq: "1001", kind: "observation", localId: "9001",
			payload: observationPayload({
				project: "mcp-proj-a", title: "First zeppelin sighting", type: "discovery",
				narrative: "a zeppelin crossed the harbor",
				created_at: "2026-08-10T00:00:00.000Z", created_at_epoch: "1786320000000",
			}),
		}),
		await contentOp({
			seq: "1002", kind: "observation", localId: "9002",
			payload: observationPayload({
				project: "mcp-proj-a", title: "Second zeppelin sighting", type: "bugfix",
				narrative: "the zeppelin returned at dusk",
				created_at: "2026-08-12T00:00:00.000Z", created_at_epoch: "1786492800000",
			}),
		}),
		await contentOp({
			seq: "1003", kind: "observation", localId: "9003",
			payload: observationPayload({
				project: "mcp-proj-b", title: "Zeppelin in another project", type: "discovery",
				narrative: "unrelated zeppelin elsewhere",
				created_at: "2026-08-14T00:00:00.000Z", created_at_epoch: "1786665600000",
			}),
		}),
		await contentOp({
			seq: "1004", kind: "observation", localId: "9004",
			payload: observationPayload({
				project: "mcp-proj-a", title: "Quiet gondola note", type: "discovery",
				narrative: "nothing airborne today",
				created_at: "2026-08-16T00:00:00.000Z", created_at_epoch: "1786838400000",
			}),
		}),
		await contentOp({
			seq: "1005", kind: "summary", localId: "9101",
			payload: summaryPayload({
				project: "mcp-proj-a", request: "chronicle the zeppelins",
				created_at: "2026-08-16T01:00:00.000Z", created_at_epoch: "1786842000000",
			}),
		}),
	];
	const res = await SELF.fetch(projectRequest(projectionBody({ ops, throughSeq: "1005" })));
	expect(res.status).toBe(200);
});

describe("mcp auth", () => {
	it("401s a missing bearer on /mcp", async () => {
		const res = await rpc({ jsonrpc: "2.0", id: 1, method: "tools/list" }, { token: null });
		expect(res.status).toBe(401);
	});

	it("401s a wrong bearer on /mcp", async () => {
		const res = await rpc({ jsonrpc: "2.0", id: 1, method: "tools/list" }, { token: "wrong" });
		expect(res.status).toBe(401);
	});

	it("401s a wrong path token on /u/<token>/mcp", async () => {
		const res = await rpc({ jsonrpc: "2.0", id: 1, method: "tools/list" }, {
			path: "/u/wrong-token/mcp",
			token: null,
		});
		expect(res.status).toBe(401);
	});

	it("accepts the path-token form without a header", async () => {
		const res = await rpc({ jsonrpc: "2.0", id: 1, method: "tools/list" }, {
			path: `/u/${MCP_TOKEN}/mcp`,
			token: null,
		});
		expect(res.status).toBe(200);
	});
});

describe("mcp protocol basics", () => {
	it("answers initialize with server info and tool capability", async () => {
		const res = await rpc({
			jsonrpc: "2.0",
			id: 1,
			method: "initialize",
			params: {
				protocolVersion: "2025-06-18",
				capabilities: {},
				clientInfo: { name: "test", version: "0.0.0" },
			},
		});
		expect(res.status).toBe(200);
		const body = (await res.json()) as JsonRpcResponse;
		const result = body.result as Record<string, unknown>;
		expect(result.protocolVersion).toBe("2025-06-18");
		expect((result.serverInfo as { name: string }).name).toBe("cmem-self-host");
		expect((result.capabilities as { tools: unknown }).tools).toBeDefined();
	});

	it("reports MCP_SERVER_NAME when set, so isolated groups are distinguishable", async () => {
		const previous = env.MCP_SERVER_NAME;
		env.MCP_SERVER_NAME = "cmem-self-host-personal-2";
		try {
			const res = await rpc({
				jsonrpc: "2.0",
				id: nextId++,
				method: "initialize",
				params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0.0.0" } },
			});
			const body = (await res.json()) as JsonRpcResponse;
			const result = body.result as Record<string, unknown>;
			expect((result.serverInfo as { name: string }).name).toBe("cmem-self-host-personal-2");
		} finally {
			env.MCP_SERVER_NAME = previous;
		}
	});

	it("falls back to the default name when MCP_SERVER_NAME is blank", async () => {
		const previous = env.MCP_SERVER_NAME;
		env.MCP_SERVER_NAME = "   ";
		try {
			const res = await rpc({
				jsonrpc: "2.0",
				id: nextId++,
				method: "initialize",
				params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0.0.0" } },
			});
			const body = (await res.json()) as JsonRpcResponse;
			const result = body.result as Record<string, unknown>;
			expect((result.serverInfo as { name: string }).name).toBe("cmem-self-host");
		} finally {
			env.MCP_SERVER_NAME = previous;
		}
	});

	it("accepts notifications/initialized with 202", async () => {
		const res = await rpc({ jsonrpc: "2.0", method: "notifications/initialized" });
		expect(res.status).toBe(202);
	});

	it("405s GET (no SSE stream offered)", async () => {
		const res = await SELF.fetch(`${base}/mcp`, {
			headers: { Authorization: `Bearer ${MCP_TOKEN}` },
		});
		expect(res.status).toBe(405);
	});

	it("lists the five tools", async () => {
		const res = await rpc({ jsonrpc: "2.0", id: 2, method: "tools/list" });
		const body = (await res.json()) as JsonRpcResponse;
		const tools = (body.result as { tools: Array<{ name: string }> }).tools.map((tool) => tool.name);
		expect(tools).toEqual(
			expect.arrayContaining([
				"search", "timeline", "get_observations", "recent_memories", "important_workflow",
			]),
		);
	});

	it("errors an unknown method with -32601", async () => {
		const res = await rpc({ jsonrpc: "2.0", id: 3, method: "does/not-exist" });
		const body = (await res.json()) as JsonRpcResponse;
		expect(body.error?.code).toBe(-32601);
	});
});

describe("search", () => {
	it("returns compact index rows, newest first", async () => {
		const result = await callTool("search", { query: "zeppelin", project: "mcp-proj-a" });
		const rows = result.results as Array<Record<string, unknown>>;
		expect(rows.length).toBe(2);
		expect(rows[0].title).toBe("Second zeppelin sighting");
		expect(rows[1].title).toBe("First zeppelin sighting");
		expect(typeof rows[0].id).toBe("number");
		expect(rows[0].project).toBe("mcp-proj-a");
	});

	it("honors the project filter", async () => {
		const result = await callTool("search", { query: "zeppelin", project: "mcp-proj-b" });
		const rows = result.results as Array<Record<string, unknown>>;
		expect(rows.length).toBe(1);
		expect(rows[0].title).toBe("Zeppelin in another project");
	});

	it("honors the obs_type filter", async () => {
		const result = await callTool("search", {
			query: "zeppelin", project: "mcp-proj-a", obs_type: "bugfix",
		});
		const rows = result.results as Array<Record<string, unknown>>;
		expect(rows.length).toBe(1);
		expect(rows[0].title).toBe("Second zeppelin sighting");
	});

	it("honors date range filters", async () => {
		const result = await callTool("search", {
			query: "zeppelin",
			dateStart: "2026-08-11T00:00:00.000Z",
			dateEnd: "2026-08-13T00:00:00.000Z",
		});
		const rows = result.results as Array<Record<string, unknown>>;
		expect(rows.length).toBe(1);
		expect(rows[0].title).toBe("Second zeppelin sighting");
	});

	it("honors limit", async () => {
		const result = await callTool("search", { query: "zeppelin", limit: 1 });
		expect((result.results as unknown[]).length).toBe(1);
	});

	it("survives FTS metacharacters in the query", async () => {
		const result = await callTool("search", { query: 'zeppelin AND ("dusk*' });
		expect(Array.isArray(result.results)).toBe(true);
	});
});

describe("timeline", () => {
	it("returns chronological context around the anchor", async () => {
		const search = await callTool("search", { query: "\"Second zeppelin sighting\"" });
		const anchorId = (search.results as Array<{ id: number }>)[0].id;
		const result = await callTool("timeline", {
			anchor: anchorId, depth_before: 1, depth_after: 1, project: "mcp-proj-a",
		});
		const rows = result.timeline as Array<Record<string, unknown>>;
		expect(rows.map((row) => row.title)).toEqual([
			"First zeppelin sighting",
			"Second zeppelin sighting",
			"Quiet gondola note",
		]);
		expect(rows[1].is_anchor).toBe(true);
	});
});

describe("get_observations", () => {
	it("fetches full rows for ids and tolerates an unknown id", async () => {
		const search = await callTool("search", { query: "zeppelin", project: "mcp-proj-a" });
		const ids = (search.results as Array<{ id: number }>).map((row) => row.id);
		const result = await callTool("get_observations", { ids: [...ids, 999999] });
		const rows = result.observations as Array<Record<string, unknown>>;
		expect(rows.length).toBe(2);
		const titles = rows.map((row) => row.title);
		expect(titles).toEqual(
			expect.arrayContaining(["First zeppelin sighting", "Second zeppelin sighting"]),
		);
		expect(rows[0].narrative).toBeTruthy();
		expect(Array.isArray(rows[0].facts)).toBe(true);
	});
});

describe("recent_memories", () => {
	it("returns the newest observations first with summaries alongside", async () => {
		const result = await callTool("recent_memories", { project: "mcp-proj-a", limit: 2 });
		const observations = result.observations as Array<Record<string, unknown>>;
		expect(observations.length).toBe(2);
		expect(observations[0].title).toBe("Quiet gondola note");
		expect(observations[1].title).toBe("Second zeppelin sighting");
		const summaries = result.summaries as Array<Record<string, unknown>>;
		expect(summaries[0].request).toBe("chronicle the zeppelins");
	});
});

describe("important_workflow", () => {
	it("describes the 3-layer search workflow", async () => {
		const res = await rpc({
			jsonrpc: "2.0",
			id: nextId++,
			method: "tools/call",
			params: { name: "important_workflow", arguments: {} },
		});
		const body = (await res.json()) as JsonRpcResponse;
		const content = (body.result as { content: Array<{ text: string }> }).content;
		expect(content[0].text).toContain("search");
		expect(content[0].text).toContain("timeline");
		expect(content[0].text).toContain("get_observations");
	});
});
