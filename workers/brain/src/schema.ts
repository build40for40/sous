const migrations: string[] = [
  `
  CREATE TABLE recipes (
    id TEXT PRIMARY KEY,
    slug TEXT NOT NULL UNIQUE,
    source_url TEXT,
    title TEXT NOT NULL,
    data TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  CREATE INDEX recipes_created_at ON recipes (created_at);

  CREATE TABLE files (
    path TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('user', 'memory', 'recipe', 'session', 'ingredient', 'technique', 'cuisine')),
    frontmatter TEXT NOT NULL DEFAULT '{}',
    body TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL
  );

  CREATE TABLE links (
    src TEXT NOT NULL,
    dst TEXT NOT NULL,
    kind TEXT NOT NULL,
    PRIMARY KEY (src, dst, kind)
  );
  CREATE INDEX links_dst ON links (dst);

  CREATE TABLE sessions (
    id TEXT PRIMARY KEY,
    recipe_id TEXT,
    stage TEXT NOT NULL DEFAULT 'decide',
    messages TEXT NOT NULL DEFAULT '[]',
    started_at TEXT NOT NULL,
    ended_at TEXT,
    reflected_at TEXT,
    reflection TEXT
  );
  CREATE INDEX sessions_recipe_id ON sessions (recipe_id);
  `,
  `
  ALTER TABLE sessions ADD COLUMN model TEXT;
  ALTER TABLE sessions ADD COLUMN context TEXT NOT NULL DEFAULT '';
  ALTER TABLE sessions ADD COLUMN turns TEXT NOT NULL DEFAULT '[]';
  ALTER TABLE sessions ADD COLUMN facts TEXT NOT NULL DEFAULT '[]';
  `,
  `
  ALTER TABLE sessions ADD COLUMN rating INTEGER;
  ALTER TABLE sessions ADD COLUMN notes TEXT;
  ALTER TABLE sessions ADD COLUMN reflection_error TEXT;
  `,
];

export const SCHEMA_VERSION = migrations.length;

/** Applies pending migrations and returns the version the database started at. */
export function migrate(sql: SqlStorage, now: string): number {
  sql.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)");
  const from = sql.exec<{ version: number }>("SELECT COALESCE(MAX(version), 0) AS version FROM schema_migrations").one().version;
  for (let version = from + 1; version <= migrations.length; version++) {
    sql.exec(migrations[version - 1]);
    sql.exec("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)", version, now);
  }
  return from;
}
