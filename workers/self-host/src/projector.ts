/**
 * POST /internal/project — the projection endpoint the sync hub requires
 * before a push can succeed (drainProjection in workers/sync-hub/src/index.ts).
 *
 * Contract highlights, in the hub's terms:
 *   - The response MUST echo {protocol_version:1, epoch, projected_through_seq:
 *     through_seq} exactly; anything else is projection_response_mismatch and
 *     the hub retries the page forever.
 *   - Pages replay at-least-once (lease races, timeouts, hub resets), so
 *     application is guarded by entity_rev on the entities table.
 *   - One malformed op must never wedge the checkpoint: it is recorded in
 *     skipped_ops and the page still succeeds. A 409 would poison the whole
 *     log (the hub treats it as deterministic and nonretryable), so this
 *     projector never answers 409.
 *
 * Epoch semantics: on a hub reset the epoch changes and the log replays from
 * seq 0. The entity_rev guard makes that replay a no-op for rows we already
 * hold, so no per-epoch checkpoint is tracked here.
 */

import {
	type CanonicalContentBody,
	type CanonicalMutation,
	compareCanonicalDecimals,
	parseCanonicalOperation,
	stableDocumentId,
} from "../../sync-hub/src/canonical-content";
import { authorized } from "./auth";
import { ensureSchema } from "./schema";

const CANONICAL_DECIMAL = /^(?:0|[1-9][0-9]*)$/;

interface WireOp {
	seq: string;
	body: string;
	operation_sha256: string;
}

interface Envelope {
	epoch: string;
	throughSeq: string;
	ops: WireOp[];
}

export async function handleProject(request: Request, env: Env): Promise<Response> {
	if (!(await authorized(request, env.CMEM_INTERNAL_PROJECTOR_SECRET))) {
		return Response.json({ error: "invalid internal projector credential" }, { status: 401 });
	}
	let parsed: unknown;
	try {
		parsed = await request.json();
	} catch {
		return Response.json({ error: "request body is not JSON" }, { status: 400 });
	}
	const envelope = parseEnvelope(parsed);
	if (envelope === null) {
		return Response.json(
			{ error: "expected {protocol_version:1, user_id, epoch, from_seq_exclusive, through_seq, ops[]}" },
			{ status: 400 },
		);
	}

	await ensureSchema(env.MEMDB);
	await applyPage(env.MEMDB, envelope.ops);

	return Response.json({
		protocol_version: 1,
		epoch: envelope.epoch,
		projected_through_seq: envelope.throughSeq,
	});
}

/**
 * Apply one page with a bounded number of D1 round trips: parse everything,
 * prefetch every entity's current rev in chunked SELECTs, walk the ops in
 * seq order against an in-memory rev map, and commit all surviving
 * statements in ONE db.batch (a single D1 transaction). The naive
 * one-read-one-write-per-op shape (~200 sequential round trips for a full
 * 100-op page) took long enough that pushing clients timed out mid-drain
 * and the projection checkpoint crawled a page per 90s lease cycle.
 */
async function applyPage(db: D1Database, ops: readonly WireOp[]): Promise<void> {
	const parsed: Array<{ seq: string; body: CanonicalContentBody }> = [];
	for (const op of ops) {
		try {
			const { body } = await parseCanonicalOperation({
				body: op.body,
				operation_sha256: op.operation_sha256,
			});
			parsed.push({ seq: op.seq, body });
		} catch (error) {
			// A malformed op must never wedge the checkpoint — record and skip.
			await recordSkip(db, op.seq, error);
		}
	}
	if (parsed.length === 0) return;

	const revs = await fetchCurrentRevs(db, parsed.map(({ body }) => body.id));
	const statements: D1PreparedStatement[] = [];
	for (const { seq, body } of parsed) {
		const current = revs.get(body.id);
		if (current !== undefined && compareCanonicalDecimals(current, body.entity_rev) >= 0) {
			continue; // replayed page or stale rev — already reflected
		}
		try {
			statements.push(
				db
					.prepare(
						`INSERT INTO entities (entity_id, kind, entity_rev, deleted) VALUES (?, ?, ?, ?)
						 ON CONFLICT(entity_id) DO UPDATE SET entity_rev = excluded.entity_rev, deleted = excluded.deleted`,
					)
					.bind(body.id, body.kind, body.entity_rev, body.deleted ? 1 : 0),
			);
			if (body.kind === "mutation") {
				statements.push(...(await mutationStatements(db, body.mutation as CanonicalMutation)));
			} else if (body.deleted) {
				statements.push(
					db.prepare(`DELETE FROM ${tableFor(body.kind)} WHERE entity_id = ?`).bind(body.id),
				);
			} else {
				statements.push(contentUpsert(db, body));
			}
			revs.set(body.id, body.entity_rev); // later ops in this page see this rev
		} catch (error) {
			// An op the canonical validator accepted but we cannot translate must
			// not wedge the checkpoint either — record it and move on.
			await recordSkip(db, seq, error);
		}
	}
	if (statements.length > 0) {
		await db.batch(statements);
	}
}

/** D1 caps bound parameters per statement; read the rev map in chunks. */
const REV_CHUNK = 50;

async function fetchCurrentRevs(
	db: D1Database,
	entityIds: readonly string[],
): Promise<Map<string, string>> {
	const unique = [...new Set(entityIds)];
	const revs = new Map<string, string>();
	for (let i = 0; i < unique.length; i += REV_CHUNK) {
		const chunk = unique.slice(i, i + REV_CHUNK);
		const rows = await db
			.prepare(
				`SELECT entity_id, entity_rev FROM entities
				 WHERE entity_id IN (${chunk.map(() => "?").join(", ")})`,
			)
			.bind(...chunk)
			.all<{ entity_id: string; entity_rev: string }>();
		for (const row of rows.results) revs.set(row.entity_id, row.entity_rev);
	}
	return revs;
}

function parseEnvelope(value: unknown): Envelope | null {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
	const record = value as Record<string, unknown>;
	if (record.protocol_version !== 1) return null;
	if (typeof record.user_id !== "string" || record.user_id.length === 0) return null;
	for (const key of ["epoch", "from_seq_exclusive", "through_seq"]) {
		if (typeof record[key] !== "string" || !CANONICAL_DECIMAL.test(record[key] as string)) return null;
	}
	if (!Array.isArray(record.ops)) return null;
	const ops: WireOp[] = [];
	for (const item of record.ops) {
		if (typeof item !== "object" || item === null) return null;
		const op = item as Record<string, unknown>;
		if (
			typeof op.seq !== "string" || !CANONICAL_DECIMAL.test(op.seq)
			|| typeof op.body !== "string" || typeof op.operation_sha256 !== "string"
		) {
			return null;
		}
		ops.push({ seq: op.seq, body: op.body, operation_sha256: op.operation_sha256 });
	}
	return { epoch: record.epoch as string, throughSeq: record.through_seq as string, ops };
}

async function recordSkip(db: D1Database, seq: string, error: unknown): Promise<void> {
	const reason = error instanceof Error ? error.message : String(error);
	await db
		.prepare(
			`INSERT INTO skipped_ops (seq, reason) VALUES (?, ?)
			 ON CONFLICT(seq) DO UPDATE SET reason = excluded.reason`,
		)
		.bind(seq, reason.slice(0, 500))
		.run();
}

function tableFor(kind: "observation" | "summary" | "prompt"): string {
	return kind === "observation"
		? "observations"
		: kind === "summary" ? "session_summaries" : "user_prompts";
}

const CONTENT_COLUMNS = {
	observation: [
		"project", "memory_session_id", "type", "title", "subtitle", "text", "narrative",
		"facts", "concepts", "files_read", "files_modified", "prompt_number",
		"discovery_tokens", "content_hash", "generated_by_model", "merged_into_project",
		"agent_type", "agent_id", "metadata",
	],
	summary: [
		"project", "memory_session_id", "request", "investigated", "learned", "completed",
		"next_steps", "notes", "files_read", "files_edited", "prompt_number",
		"discovery_tokens", "merged_into_project",
	],
	prompt: [
		"project", "content_session_id", "memory_session_id", "platform_source",
		"prompt_number", "prompt_text",
	],
} as const;

function contentUpsert(db: D1Database, body: CanonicalContentBody): D1PreparedStatement {
	const kind = body.kind as keyof typeof CONTENT_COLUMNS;
	const payload = body.payload as Record<string, unknown>;
	const columns = CONTENT_COLUMNS[kind];
	const values = columns.map((column) => columnValue(payload[column]));
	const createdAt = payload.created_at as string;
	const createdAtEpoch = Number(payload.created_at_epoch as string);
	const allColumns = ["entity_id", ...columns, "created_at", "created_at_epoch"];
	const placeholders = allColumns.map(() => "?").join(", ");
	const updates = allColumns
		.filter((column) => column !== "entity_id")
		.map((column) => `${column} = excluded.${column}`)
		.join(", ");
	return db
		.prepare(
			`INSERT INTO ${tableFor(kind)} (${allColumns.join(", ")}) VALUES (${placeholders})
			 ON CONFLICT(entity_id) DO UPDATE SET ${updates}`,
		)
		.bind(body.id, ...values, createdAt, createdAtEpoch);
}

/** Arrays and metadata objects persist as JSON text; scalars pass through. */
function columnValue(value: unknown): string | null {
	if (value === undefined || value === null) return null;
	if (typeof value === "string") return value;
	return JSON.stringify(value);
}

async function mutationStatements(
	db: D1Database,
	mutation: CanonicalMutation,
): Promise<D1PreparedStatement[]> {
	if (mutation.op === "set_title") {
		const target = mutation.target ?? {};
		const key = (target.memory_session_id ?? target.content_session_id) as string;
		return [
			db
				.prepare(
					`INSERT INTO session_titles (session_key, custom_title) VALUES (?, ?)
					 ON CONFLICT(session_key) DO UPDATE SET custom_title = excluded.custom_title`,
				)
				.bind(key, mutation.fields.custom_title as string),
		];
	}
	if (mutation.op === "set_prompt_session") {
		const target = mutation.target as Record<string, unknown>;
		const entityId = await stableDocumentId(
			"prompt",
			target.origin_device_id as string,
			target.origin_local_id as string,
		);
		const assignable = ["memory_session_id", "content_session_id", "platform_source", "project"] as const;
		const sets: string[] = [];
		const params: string[] = [];
		for (const field of assignable) {
			const value = mutation.fields[field];
			if (typeof value === "string") {
				sets.push(`${field} = ?`);
				params.push(value);
			}
		}
		return [
			db
				.prepare(`UPDATE user_prompts SET ${sets.join(", ")} WHERE entity_id = ?`)
				.bind(...params, entityId),
		];
	}
	// remap_project — same table scope as the client-side SyncApply: content
	// rows in observations and session_summaries only.
	const where = mutation.where as Record<string, unknown>;
	const sets: string[] = [];
	const setParams: string[] = [];
	if (typeof mutation.fields.project === "string") {
		sets.push("project = ?");
		setParams.push(mutation.fields.project);
	}
	if (typeof mutation.fields.merged_into_project === "string") {
		sets.push("merged_into_project = ?");
		setParams.push(mutation.fields.merged_into_project);
	}
	const clauses: string[] = [];
	const whereParams: string[] = [];
	if (typeof where.project === "string") {
		clauses.push("project = ?");
		whereParams.push(where.project);
	}
	if (typeof where.memory_session_id === "string") {
		clauses.push("memory_session_id = ?");
		whereParams.push(where.memory_session_id);
	}
	if (where.merged_into_project_is_null === true) {
		clauses.push("merged_into_project IS NULL");
	}
	return ["observations", "session_summaries"].map((table) =>
		db
			.prepare(`UPDATE ${table} SET ${sets.join(", ")} WHERE ${clauses.join(" AND ")}`)
			.bind(...setParams, ...whereParams),
	);
}
