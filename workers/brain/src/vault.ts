import type { Recipe } from "@sous/contracts";
import type { JsonValue } from "./profile";
import { USER_MD } from "./profile";
import { recipeNotePath } from "./prompt";
import type { Reflection } from "./reflection";
import { slugify } from "./recipes";
import { linkKind, parseWikilinks, wikilink } from "./wikilinks";

export type NoteKind = "user" | "memory" | "recipe" | "session" | "ingredient" | "technique" | "cuisine";

type Frontmatter = { [key: string]: JsonValue };

interface FileRow extends Record<string, SqlStorageValue> {
  path: string;
  frontmatter: string;
  body: string;
}

export interface ReflectedSession {
  id: string;
  started_at: string;
  recipe: Pick<Recipe, "id" | "slug" | "title" | "source_url"> | null;
  notes: string | null;
  reflection: Reflection;
}

interface Topic {
  name: string;
  path: string;
}

const TOPIC_FOLDERS = { ingredient: "ingredients", technique: "techniques", cuisine: "cuisines" } as const;
const LEARNED = "Learned while cooking";

export const londonDate = (iso: string) => new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/London" }).format(new Date(iso));
export const londonDay = (iso: string) => new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", day: "numeric", month: "long", year: "numeric" }).format(new Date(iso));

export function sessionNotePath(session: Pick<ReflectedSession, "id" | "started_at" | "recipe">): string {
  return `sessions/${londonDate(session.started_at)}-${session.recipe?.slug ?? "cook"}-${session.id.slice(0, 8)}.md`;
}

/** Rewrites the list under `## heading`, adding the section at the end when it's missing and dropping it when it ends up empty. */
export function editSection(body: string, heading: string, edit: (lines: string[]) => string[]): string {
  const lines = body.replace(/\s+$/, "").split("\n");
  const start = lines.indexOf(`## ${heading}`);
  const end = start === -1 ? lines.length : nextHeading(lines, start + 1);
  const current = start === -1 ? [] : lines.slice(start + 1, end).filter((l) => l.trim());
  const next = edit(current);
  const before = (start === -1 ? lines : lines.slice(0, start)).join("\n").replace(/\s+$/, "");
  const after = lines.slice(end).join("\n").replace(/\s+$/, "");
  const section = next.length ? `## ${heading}\n\n${next.join("\n")}` : "";
  return `${[before, section, after].filter(Boolean).join("\n\n")}\n`;
}

/** Swaps one session's lines for new ones, leaving every other session's lines alone. */
export const replaceSessionLines = (key: string, lines: string[]) => (current: string[]) => [...current.filter((l) => !l.includes(key)), ...lines];

/** Adds the lines that aren't there yet. */
export const addLines = (lines: string[]) => (current: string[]) => [...new Set([...current, ...lines])];

/** Writes everything one reflection learned into the vault, then rebuilds the links. Running it again with the same input changes nothing. */
export function writeReflection(sql: SqlStorage, session: ReflectedSession, now: string): string {
  const { recipe, reflection } = session;
  const sessionPath = sessionNotePath(session);
  const sessionLink = wikilink(sessionPath);
  const recipePath = recipe ? recipeNotePath(recipe.slug!) : null;
  const day = londonDay(session.started_at);
  const rating = reflection.rating ? `${reflection.rating}/5` : null;
  const topics = {
    ingredient: topicsOf("ingredient", reflection.ingredients),
    technique: topicsOf("technique", reflection.techniques),
    cuisine: topicsOf("cuisine", reflection.cuisine ? [reflection.cuisine] : []),
  };
  const topicLinks = (list: Topic[]) => list.map((t) => `- ${wikilink(t.path, t.name)}`);

  writeFile(sql, sessionPath, "session", sessionFrontmatter(session), sessionBody(session, recipePath, topics), now);

  if (recipe && recipePath) {
    const existing = readFile(sql, recipePath);
    let body = existing?.body ?? `# ${recipe.title}\n${recipe.source_url ? `\nSource: ${recipe.source_url}\n` : ""}`;
    body = editSection(body, "Cooks", replaceSessionLines(sessionLink, [`- ${sessionLink} ${day}${rating ? `, ${rating}` : ""}: ${reflection.summary}`]));
    body = editSection(body, "Next time", replaceSessionLines(sessionLink, reflection.failed.map((f) => `- ${f} (${sessionLink})`)));
    body = editSection(body, "Swaps", replaceSessionLines(sessionLink, reflection.substitutions.map((s) => `- ${swap(s)} (${sessionLink})`)));
    body = editSection(body, "Ingredients", addLines(topicLinks(topics.ingredient)));
    body = editSection(body, "Techniques", addLines(topicLinks(topics.technique)));
    body = editSection(body, "Cuisine", addLines(topicLinks(topics.cuisine)));
    const cooks = sectionLines(body, "Cooks");
    const frontmatter: Frontmatter = {
      ...existing?.frontmatter,
      recipe_id: recipe.id!,
      title: recipe.title,
      times_cooked: cooks.length,
      last_cooked: cooks.map((l) => l.match(/\[\[sessions\/(\d{4}-\d{2}-\d{2})/)?.[1] ?? "").sort().at(-1) ?? null,
    };
    writeFile(sql, recipePath, "recipe", frontmatter, body, now);
  }

  const usedIn = `- ${sessionLink}${recipePath ? ` in ${wikilink(recipePath, recipe!.title)}` : ""}, ${day}${rating ? `, ${rating}` : ""}`;
  for (const [kind, list] of Object.entries(topics) as [keyof typeof TOPIC_FOLDERS, Topic[]][]) {
    for (const topic of list) {
      const existing = readFile(sql, topic.path);
      const body = editSection(existing?.body ?? `# ${topic.name}\n`, "Cooked in", replaceSessionLines(sessionLink, [usedIn]));
      writeFile(sql, topic.path, kind, { ...existing?.frontmatter, name: (existing?.frontmatter.name as string) ?? topic.name }, body, now);
    }
  }

  const user = readFile(sql, USER_MD);
  if (user) {
    const body = editSection(user.body, LEARNED, (current) => {
      const others = current.filter((l) => !l.includes(sessionLink));
      const known = new Set(others.map(preferenceText));
      const added = reflection.preferences.filter((p) => !known.has(p.toLowerCase())).map((p) => `- ${p} (${sessionLink})`);
      return [...others, ...added];
    });
    writeFile(sql, USER_MD, "user", user.frontmatter, body, now);
  }

  rebuildLinks(sql);
  return sessionPath;
}

/** Throws away the links table and reads it back from every note's [[wikilinks]]. */
export function rebuildLinks(sql: SqlStorage): void {
  sql.exec("DELETE FROM links");
  for (const { path, body } of sql.exec<FileRow>("SELECT path, body FROM files ORDER BY path").toArray()) {
    for (const dst of parseWikilinks(body)) {
      if (dst !== path) sql.exec("INSERT OR IGNORE INTO links (src, dst, kind) VALUES (?, ?, ?)", path, dst, linkKind(dst));
    }
  }
}

function sessionFrontmatter({ id, started_at, recipe, reflection }: ReflectedSession): Frontmatter {
  return {
    session_id: id,
    recipe_id: recipe?.id ?? null,
    date: londonDate(started_at),
    rating: reflection.rating,
    cuisine: reflection.cuisine,
    ingredients: reflection.ingredients,
    techniques: reflection.techniques,
  };
}

function sessionBody(session: ReflectedSession, recipePath: string | null, topics: Record<keyof typeof TOPIC_FOLDERS, Topic[]>): string {
  const { recipe, reflection, notes } = session;
  const bullets = (items: string[]) => items.map((i) => `- ${i}`).join("\n");
  const header = [
    recipePath ? `Recipe: ${wikilink(recipePath, recipe!.title)}` : null,
    `Rating: ${reflection.rating ? `${reflection.rating}/5` : "not rated"}`,
    topics.cuisine.length ? `Cuisine: ${topics.cuisine.map((t) => wikilink(t.path, t.name)).join(", ")}` : null,
  ].filter(Boolean);
  const sections: [string, string][] = [
    ["What worked", bullets(reflection.worked)],
    ["What didn't", bullets(reflection.failed)],
    ["Swaps", bullets(reflection.substitutions.map(swap))],
    ["Learned about the cook", bullets(reflection.preferences)],
    ["Ingredients", bullets(topics.ingredient.map((t) => wikilink(t.path, t.name)))],
    ["Techniques", bullets(topics.technique.map((t) => wikilink(t.path, t.name)))],
    ["Cook's notes", notes ?? ""],
  ];
  return [
    `# ${recipe?.title ?? "A cook"}, ${londonDay(session.started_at)}`,
    header.join("\n"),
    reflection.summary,
    ...sections.filter(([, body]) => body).map(([heading, body]) => `## ${heading}\n\n${body}`),
  ]
    .filter(Boolean)
    .join("\n\n")
    .concat("\n");
}

function topicsOf(kind: keyof typeof TOPIC_FOLDERS, names: string[]): Topic[] {
  const bySlug = new Map<string, Topic>();
  for (const name of names) {
    if (!/[a-z0-9]/i.test(name.normalize("NFKD"))) continue;
    const path = `${TOPIC_FOLDERS[kind]}/${slugify(name)}.md`;
    if (!bySlug.has(path)) bySlug.set(path, { name, path });
  }
  return [...bySlug.values()];
}

function swap(s: { original: string; replacement: string; outcome: string }): string {
  return `${s.replacement} instead of ${s.original}${s.outcome ? `: ${s.outcome}` : ""}`;
}

function preferenceText(line: string): string {
  return line.replace(/^- /, "").replace(/ \(\[\[[^\]]*\]\]\)$/, "").toLowerCase();
}

function sectionLines(body: string, heading: string): string[] {
  let found: string[] = [];
  editSection(body, heading, (lines) => (found = lines));
  return found;
}

function nextHeading(lines: string[], from: number): number {
  for (let i = from; i < lines.length; i++) if (/^#{1,2} /.test(lines[i])) return i;
  return lines.length;
}

function readFile(sql: SqlStorage, path: string): { frontmatter: Frontmatter; body: string } | null {
  const row = sql.exec<FileRow>("SELECT path, frontmatter, body FROM files WHERE path = ?", path).toArray()[0];
  return row ? { frontmatter: JSON.parse(row.frontmatter), body: row.body } : null;
}

/** Saves a note, leaving it and its updated_at untouched when nothing changed. */
function writeFile(sql: SqlStorage, path: string, kind: NoteKind, frontmatter: Frontmatter, body: string, now: string): void {
  sql.exec(
    `INSERT INTO files (path, kind, frontmatter, body, updated_at) VALUES (?, ?, ?, ?, ?)
     ON CONFLICT (path) DO UPDATE SET kind = excluded.kind, frontmatter = excluded.frontmatter, body = excluded.body, updated_at = excluded.updated_at
     WHERE files.kind IS NOT excluded.kind OR files.frontmatter IS NOT excluded.frontmatter OR files.body IS NOT excluded.body`,
    path,
    kind,
    JSON.stringify(frontmatter),
    body,
    now,
  );
}
