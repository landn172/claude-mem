/**
 * Remote MCP endpoint: stateless Streamable HTTP (JSON-RPC over POST). No
 * session state, no SSE stream (GET answers 405, which the spec permits for
 * servers that don't offer one), no batching (removed in protocol
 * 2025-06-18). Tool names and the index-first contract mirror the local MCP
 * server (src/servers/mcp-server.ts); the numeric ids are the D1 rowids of
 * the projected observations.
 */

import { authorized, bearerToken, secretsMatch } from "./auth";
import { ensureSchema } from "./schema";

const DEFAULT_PROTOCOL = "2025-06-18";
const DEFAULT_SERVER_NAME = "cmem-self-host";
const SUPPORTED_PROTOCOLS = new Set(["2024-11-05", "2025-03-26", "2025-06-18"]);

const WORKFLOW_TEXT = `# Memory Search Workflow

**3-Layer Pattern (ALWAYS follow this):**

1. **search** - Get an index of results with IDs
   search(query="...", limit=20, project="...")
   Returns: compact rows with ids, titles, dates (~50-100 tokens/result)

2. **timeline** - Get context around interesting results
   timeline(anchor=<ID>, depth_before=3, depth_after=3)
   Returns: chronological context showing what was happening

3. **get_observations** - Fetch full details ONLY for filtered IDs
   get_observations(ids=[...])
   Returns: complete details (~500-1000 tokens/result)

**Why:** 10x token savings. Never fetch full details without filtering first.`;

interface ToolDefinition {
	name: string;
	description: string;
	inputSchema: Record<string, unknown>;
}

const TOOLS: ToolDefinition[] = [
	{
		name: "important_workflow",
		description: "3-LAYER WORKFLOW (ALWAYS FOLLOW): search → timeline → get_observations. Never fetch full details without filtering first.",
		inputSchema: { type: "object", properties: {} },
	},
	{
		name: "search",
		description: "Step 1: Search memory. Returns an index with numeric ids. Params: query, limit, project, obs_type, dateStart, dateEnd, offset",
		inputSchema: {
			type: "object",
			properties: {
				query: { type: "string", description: "Search query" },
				limit: { type: "number", description: "Max results (default 20)" },
				project: { type: "string", description: "Filter by project name" },
				obs_type: { type: "string", description: "Filter observations by type (comma-separated for multiple)" },
				dateStart: { type: "string", description: "Start date filter (ISO)" },
				dateEnd: { type: "string", description: "End date filter (ISO)" },
				offset: { type: "number", description: "Pagination offset" },
			},
			required: ["query"],
		},
	},
	{
		name: "timeline",
		description: "Step 2: Get chronological context around an observation. Params: anchor (observation id), depth_before, depth_after, project",
		inputSchema: {
			type: "object",
			properties: {
				anchor: { type: "number", description: "Observation id to center the timeline around" },
				depth_before: { type: "number", description: "Items before anchor (default 3)" },
				depth_after: { type: "number", description: "Items after anchor (default 3)" },
				project: { type: "string", description: "Filter by project name" },
			},
			required: ["anchor"],
		},
	},
	{
		name: "get_observations",
		description: "Step 3: Fetch full details for filtered ids. Params: ids (array of observation ids, required)",
		inputSchema: {
			type: "object",
			properties: {
				ids: { type: "array", items: { type: "number" }, description: "Observation ids to fetch" },
			},
			required: ["ids"],
		},
	},
	{
		name: "recent_memories",
		description: "The newest observations and session summaries, optionally per project. Params: limit (default 10), project",
		inputSchema: {
			type: "object",
			properties: {
				limit: { type: "number", description: "Max rows per section (default 10)" },
				project: { type: "string", description: "Filter by project name" },
			},
		},
	},
];

export async function handleMcp(
	request: Request,
	env: Env,
	pathToken: string | null,
): Promise<Response> {
	if (!(await mcpAuthorized(request, env, pathToken))) {
		return Response.json({ error: "invalid MCP credential" }, { status: 401 });
	}
	if (request.method !== "POST") {
		// Stateless server: no SSE stream to GET, no session to DELETE.
		return new Response("method not allowed", { status: 405, headers: { Allow: "POST" } });
	}
	let message: unknown;
	try {
		message = await request.json();
	} catch {
		return jsonRpcError(null, -32700, "parse error");
	}
	if (Array.isArray(message) || typeof message !== "object" || message === null) {
		return jsonRpcError(null, -32600, "expected a single JSON-RPC message");
	}
	const rpc = message as Record<string, unknown>;
	const id = typeof rpc.id === "number" || typeof rpc.id === "string" ? rpc.id : null;
	const method = typeof rpc.method === "string" ? rpc.method : "";

	// Notifications (no id) are acknowledged and ignored.
	if (id === null || method.startsWith("notifications/")) {
		return new Response(null, { status: 202 });
	}
	if (method === "initialize") {
		const params = (rpc.params ?? {}) as Record<string, unknown>;
		const requested = typeof params.protocolVersion === "string" ? params.protocolVersion : "";
		return jsonRpcResult(id, {
			protocolVersion: SUPPORTED_PROTOCOLS.has(requested) ? requested : DEFAULT_PROTOCOL,
			capabilities: { tools: { listChanged: false } },
			serverInfo: { name: (env.MCP_SERVER_NAME ?? "").trim() || DEFAULT_SERVER_NAME, version: "1.0.0" },
		});
	}
	if (method === "ping") {
		return jsonRpcResult(id, {});
	}
	if (method === "tools/list") {
		return jsonRpcResult(id, { tools: TOOLS });
	}
	if (method === "tools/call") {
		const params = (rpc.params ?? {}) as Record<string, unknown>;
		const name = typeof params.name === "string" ? params.name : "";
		const args = (params.arguments ?? {}) as Record<string, unknown>;
		try {
			await ensureSchema(env.MEMDB);
			const text = await callTool(env.MEMDB, name, args);
			return jsonRpcResult(id, { content: [{ type: "text", text }] });
		} catch (error) {
			const reason = error instanceof Error ? error.message : String(error);
			return jsonRpcResult(id, {
				content: [{ type: "text", text: `tool error: ${reason}` }],
				isError: true,
			});
		}
	}
	return jsonRpcError(id, -32601, `method not found: ${method}`);
}

async function mcpAuthorized(
	request: Request,
	env: Env,
	pathToken: string | null,
): Promise<boolean> {
	const configured = (env.MCP_TOKEN ?? "").trim();
	if (configured.length === 0) return false; // fail-closed on missing config
	if (pathToken !== null) return secretsMatch(pathToken, configured);
	if (bearerToken(request).length === 0) return false;
	return authorized(request, configured);
}

function jsonRpcResult(id: number | string, result: Record<string, unknown>): Response {
	return Response.json({ jsonrpc: "2.0", id, result });
}

function jsonRpcError(id: number | string | null, code: number, message: string): Response {
	return Response.json({ jsonrpc: "2.0", id, error: { code, message } }, { status: code === -32700 || code === -32600 ? 400 : 200 });
}

async function callTool(
	db: D1Database,
	name: string,
	args: Record<string, unknown>,
): Promise<string> {
	switch (name) {
		case "important_workflow":
			return WORKFLOW_TEXT;
		case "search":
			return JSON.stringify(await toolSearch(db, args));
		case "timeline":
			return JSON.stringify(await toolTimeline(db, args));
		case "get_observations":
			return JSON.stringify(await toolGetObservations(db, args));
		case "recent_memories":
			return JSON.stringify(await toolRecentMemories(db, args));
		default:
			throw new Error(`unknown tool: ${name}`);
	}
}

/** Quote every token so FTS5 metacharacters cannot break the MATCH grammar. */
function ftsQuery(raw: unknown): string | null {
	if (typeof raw !== "string") return null;
	const tokens = raw.match(/[A-Za-z0-9_]+/g) ?? [];
	if (tokens.length === 0) return null;
	return tokens.map((token) => `"${token}"`).join(" ");
}

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
	if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
	return Math.min(max, Math.max(min, Math.trunc(value)));
}

function isoToEpoch(value: unknown): number | null {
	if (typeof value !== "string") return null;
	const parsed = Date.parse(value);
	return Number.isFinite(parsed) ? parsed : null;
}

interface IndexRow {
	id: number;
	type: string | null;
	title: string | null;
	subtitle: string | null;
	project: string;
	date: string;
}

async function toolSearch(
	db: D1Database,
	args: Record<string, unknown>,
): Promise<{ results: IndexRow[] }> {
	const match = ftsQuery(args.query);
	if (match === null) return { results: [] };
	const limit = clampInt(args.limit, 1, 100, 20);
	const offset = clampInt(args.offset, 0, 100_000, 0);
	const clauses: string[] = ["observations_fts MATCH ?"];
	const params: (string | number)[] = [match];
	if (typeof args.project === "string" && args.project.length > 0) {
		clauses.push("o.project = ?");
		params.push(args.project);
	}
	if (typeof args.obs_type === "string" && args.obs_type.length > 0) {
		const types = args.obs_type.split(",").map((type) => type.trim()).filter(Boolean);
		clauses.push(`o.type IN (${types.map(() => "?").join(", ")})`);
		params.push(...types);
	}
	const start = isoToEpoch(args.dateStart);
	if (start !== null) {
		clauses.push("o.created_at_epoch >= ?");
		params.push(start);
	}
	const end = isoToEpoch(args.dateEnd);
	if (end !== null) {
		clauses.push("o.created_at_epoch <= ?");
		params.push(end);
	}
	const rows = await db
		.prepare(
			`SELECT o.rowid AS id, o.type, o.title, o.subtitle, o.project, o.created_at AS date
			 FROM observations_fts
			 JOIN observations o ON o.rowid = observations_fts.rowid
			 WHERE ${clauses.join(" AND ")}
			 ORDER BY o.created_at_epoch DESC
			 LIMIT ? OFFSET ?`,
		)
		.bind(...params, limit, offset)
		.all<IndexRow>();
	return { results: rows.results };
}

async function toolTimeline(
	db: D1Database,
	args: Record<string, unknown>,
): Promise<{ timeline: Array<IndexRow & { is_anchor: boolean }> }> {
	const anchorId = clampInt(args.anchor, 1, Number.MAX_SAFE_INTEGER, 0);
	const anchor = await db
		.prepare(
			`SELECT rowid AS id, type, title, subtitle, project, created_at AS date, created_at_epoch
			 FROM observations WHERE rowid = ?`,
		)
		.bind(anchorId)
		.first<IndexRow & { created_at_epoch: number }>();
	if (!anchor) throw new Error(`no observation with id ${anchorId}`);
	const depthBefore = clampInt(args.depth_before, 0, 50, 3);
	const depthAfter = clampInt(args.depth_after, 0, 50, 3);
	const projectClause = typeof args.project === "string" && args.project.length > 0
		? "AND project = ?"
		: "";
	const projectParams = projectClause ? [args.project as string] : [];
	const before = await db
		.prepare(
			`SELECT rowid AS id, type, title, subtitle, project, created_at AS date
			 FROM observations
			 WHERE created_at_epoch < ? ${projectClause}
			 ORDER BY created_at_epoch DESC LIMIT ?`,
		)
		.bind(anchor.created_at_epoch, ...projectParams, depthBefore)
		.all<IndexRow>();
	const after = await db
		.prepare(
			`SELECT rowid AS id, type, title, subtitle, project, created_at AS date
			 FROM observations
			 WHERE created_at_epoch > ? ${projectClause}
			 ORDER BY created_at_epoch ASC LIMIT ?`,
		)
		.bind(anchor.created_at_epoch, ...projectParams, depthAfter)
		.all<IndexRow>();
	const anchorRow: IndexRow = {
		id: anchor.id,
		type: anchor.type,
		title: anchor.title,
		subtitle: anchor.subtitle,
		project: anchor.project,
		date: anchor.date,
	};
	return {
		timeline: [
			...before.results.reverse().map((row) => ({ ...row, is_anchor: false })),
			{ ...anchorRow, is_anchor: true },
			...after.results.map((row) => ({ ...row, is_anchor: false })),
		],
	};
}

const JSON_COLUMNS = new Set(["facts", "concepts", "files_read", "files_modified", "metadata"]);

async function toolGetObservations(
	db: D1Database,
	args: Record<string, unknown>,
): Promise<{ observations: Array<Record<string, unknown>> }> {
	const ids = Array.isArray(args.ids)
		? args.ids.filter((value): value is number => typeof value === "number" && Number.isFinite(value))
		: [];
	if (ids.length === 0) return { observations: [] };
	const rows = await db
		.prepare(
			`SELECT rowid AS id, project, memory_session_id, type, title, subtitle, text,
				narrative, facts, concepts, files_read, files_modified, created_at AS date
			 FROM observations WHERE rowid IN (${ids.map(() => "?").join(", ")})
			 ORDER BY created_at_epoch DESC`,
		)
		.bind(...ids)
		.all<Record<string, unknown>>();
	return {
		observations: rows.results.map((row) => {
			const parsed: Record<string, unknown> = { ...row };
			for (const column of JSON_COLUMNS) {
				if (typeof parsed[column] === "string") {
					try {
						parsed[column] = JSON.parse(parsed[column] as string);
					} catch {
						// leave the raw string in place
					}
				}
			}
			return parsed;
		}),
	};
}

async function toolRecentMemories(
	db: D1Database,
	args: Record<string, unknown>,
): Promise<{ observations: Array<Record<string, unknown>>; summaries: Array<Record<string, unknown>> }> {
	const limit = clampInt(args.limit, 1, 100, 10);
	const projectClause = typeof args.project === "string" && args.project.length > 0
		? "WHERE project = ?"
		: "";
	const projectParams = projectClause ? [args.project as string] : [];
	const observations = await db
		.prepare(
			`SELECT rowid AS id, type, title, subtitle, project, created_at AS date
			 FROM observations ${projectClause}
			 ORDER BY created_at_epoch DESC LIMIT ?`,
		)
		.bind(...projectParams, limit)
		.all<Record<string, unknown>>();
	const summaries = await db
		.prepare(
			`SELECT rowid AS id, project, memory_session_id, request, learned, completed,
				created_at AS date
			 FROM session_summaries ${projectClause}
			 ORDER BY created_at_epoch DESC LIMIT ?`,
		)
		.bind(...projectParams, limit)
		.all<Record<string, unknown>>();
	return { observations: observations.results, summaries: summaries.results };
}
