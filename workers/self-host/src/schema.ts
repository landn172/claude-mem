/**
 * D1 schema, applied lazily and idempotently (every statement is
 * IF NOT EXISTS) — no `wrangler d1 execute` deploy step. Column sets come
 * from the canonical payload contract (PAYLOAD_FIELDS in
 * workers/sync-hub/src/canonical-content.ts); rows are keyed by the stable
 * entity id, and the implicit SQLite rowid doubles as the numeric id the
 * MCP tools expose (parity with the local server's integer observation ids).
 */

export const SCHEMA_STATEMENTS: readonly string[] = [
	`CREATE TABLE IF NOT EXISTS entities (
		entity_id TEXT PRIMARY KEY,
		kind TEXT NOT NULL,
		entity_rev TEXT NOT NULL,
		deleted INTEGER NOT NULL DEFAULT 0
	)`,
	`CREATE TABLE IF NOT EXISTS observations (
		entity_id TEXT PRIMARY KEY,
		project TEXT NOT NULL,
		memory_session_id TEXT NOT NULL,
		type TEXT,
		title TEXT,
		subtitle TEXT,
		text TEXT,
		narrative TEXT,
		facts TEXT,
		concepts TEXT,
		files_read TEXT,
		files_modified TEXT,
		prompt_number TEXT,
		discovery_tokens TEXT,
		content_hash TEXT,
		generated_by_model TEXT,
		merged_into_project TEXT,
		agent_type TEXT,
		agent_id TEXT,
		metadata TEXT,
		created_at TEXT NOT NULL,
		created_at_epoch INTEGER NOT NULL
	)`,
	`CREATE INDEX IF NOT EXISTS idx_observations_project_epoch
		ON observations(project, created_at_epoch)`,
	`CREATE INDEX IF NOT EXISTS idx_observations_epoch
		ON observations(created_at_epoch)`,
	`CREATE TABLE IF NOT EXISTS session_summaries (
		entity_id TEXT PRIMARY KEY,
		project TEXT NOT NULL,
		memory_session_id TEXT NOT NULL,
		request TEXT,
		investigated TEXT,
		learned TEXT,
		completed TEXT,
		next_steps TEXT,
		notes TEXT,
		files_read TEXT,
		files_edited TEXT,
		prompt_number TEXT,
		discovery_tokens TEXT,
		merged_into_project TEXT,
		created_at TEXT NOT NULL,
		created_at_epoch INTEGER NOT NULL
	)`,
	`CREATE INDEX IF NOT EXISTS idx_summaries_project_epoch
		ON session_summaries(project, created_at_epoch)`,
	`CREATE TABLE IF NOT EXISTS user_prompts (
		entity_id TEXT PRIMARY KEY,
		project TEXT NOT NULL,
		content_session_id TEXT,
		memory_session_id TEXT,
		platform_source TEXT,
		prompt_number TEXT,
		prompt_text TEXT NOT NULL,
		created_at TEXT NOT NULL,
		created_at_epoch INTEGER NOT NULL
	)`,
	`CREATE INDEX IF NOT EXISTS idx_prompts_project_epoch
		ON user_prompts(project, created_at_epoch)`,
	`CREATE TABLE IF NOT EXISTS session_titles (
		session_key TEXT PRIMARY KEY,
		custom_title TEXT NOT NULL
	)`,
	`CREATE TABLE IF NOT EXISTS skipped_ops (
		seq TEXT PRIMARY KEY,
		reason TEXT NOT NULL,
		received_at TEXT NOT NULL DEFAULT (datetime('now'))
	)`,
	`CREATE VIRTUAL TABLE IF NOT EXISTS observations_fts USING fts5(
		title, subtitle, text, narrative, facts, concepts,
		content='observations', content_rowid='rowid'
	)`,
	`CREATE TRIGGER IF NOT EXISTS observations_fts_ai AFTER INSERT ON observations BEGIN
		INSERT INTO observations_fts(rowid, title, subtitle, text, narrative, facts, concepts)
		VALUES (new.rowid, new.title, new.subtitle, new.text, new.narrative, new.facts, new.concepts);
	END`,
	`CREATE TRIGGER IF NOT EXISTS observations_fts_ad AFTER DELETE ON observations BEGIN
		INSERT INTO observations_fts(observations_fts, rowid, title, subtitle, text, narrative, facts, concepts)
		VALUES ('delete', old.rowid, old.title, old.subtitle, old.text, old.narrative, old.facts, old.concepts);
	END`,
	`CREATE TRIGGER IF NOT EXISTS observations_fts_au AFTER UPDATE ON observations BEGIN
		INSERT INTO observations_fts(observations_fts, rowid, title, subtitle, text, narrative, facts, concepts)
		VALUES ('delete', old.rowid, old.title, old.subtitle, old.text, old.narrative, old.facts, old.concepts);
		INSERT INTO observations_fts(rowid, title, subtitle, text, narrative, facts, concepts)
		VALUES (new.rowid, new.title, new.subtitle, new.text, new.narrative, new.facts, new.concepts);
	END`,
];

let ensured: WeakSet<D1Database> | null = null;

/** Apply the schema once per database per isolate; every statement is idempotent. */
export async function ensureSchema(db: D1Database): Promise<void> {
	ensured ??= new WeakSet();
	if (ensured.has(db)) return;
	await db.batch(SCHEMA_STATEMENTS.map((statement) => db.prepare(statement)));
	ensured.add(db);
}
