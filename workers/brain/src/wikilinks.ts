const WIKILINK = /\[\[([^[\]|#\n]+)(?:#[^[\]|\n]*)?(?:\|[^[\]\n]*)?\]\]/g;

const KIND_BY_FOLDER: Record<string, string> = {
  recipes: "recipe",
  sessions: "session",
  ingredients: "ingredient",
  techniques: "technique",
  cuisines: "cuisine",
};

const KIND_BY_FILE: Record<string, string> = { "USER.md": "user", "MEMORY.md": "memory" };

/** The vault path a link target points at: `recipes/toastie` and `recipes/toastie.md` are the same note. */
export function resolveLink(target: string): string | null {
  const path = target.trim().replace(/^\/+/, "");
  if (!path) return null;
  return /\.[A-Za-z0-9]+$/.test(path) ? path : `${path}.md`;
}

/** Every distinct note a body links to with `[[target]]`, `[[target|label]]` or `[[target#heading]]`, in order. */
export function parseWikilinks(body: string): string[] {
  const paths = new Set<string>();
  for (const match of body.matchAll(WIKILINK)) {
    const path = resolveLink(match[1]);
    if (path) paths.add(path);
  }
  return [...paths];
}

/** A link's kind is the kind of note it points at, from the folder it lives in. */
export function linkKind(path: string): string {
  return KIND_BY_FILE[path] ?? KIND_BY_FOLDER[path.split("/")[0]] ?? "note";
}

export function wikilink(path: string, label?: string): string {
  const target = path.replace(/\.md$/, "");
  return label ? `[[${target}|${label}]]` : `[[${target}]]`;
}
