import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import type { UserBrain } from "./brain";
import type { Reflection } from "./reflection";
import { addLines, editSection, londonDate, londonDay, rebuildLinks, replaceAbout, replaceSessionLines, sessionNotePath, splitLearned, writeReflection, type ReflectedSession } from "./vault";

const recipe = { id: "recipe-1", slug: "fake-toastie", title: "Fake Toastie", source_url: "https://example.com/sous/fake-toastie" };

const reflection: Reflection = {
  rating: 4,
  summary: "Golden and gooey.",
  worked: ["Buttering edge to edge"],
  failed: ["Lower the heat a touch"],
  substitutions: [{ original: "cheddar", replacement: "red leicester", outcome: "Melted well" }],
  preferences: ["Hates coriander"],
  ingredients: ["bread", "red leicester", "butter"],
  techniques: ["toasting"],
  cuisine: "british",
};

const session = (overrides: Partial<ReflectedSession> = {}): ReflectedSession => ({
  id: "aaaaaaaa-1111-4111-8111-111111111111",
  started_at: "2026-11-06T18:00:00Z",
  recipe,
  notes: "Next time, more butter.",
  reflection,
  ...overrides,
});

async function inVault<T>(name: string, run: (sql: SqlStorage) => T): Promise<T> {
  return runInDurableObject(env.USER_BRAIN.get(env.USER_BRAIN.idFromName(name)), (brain: UserBrain, state) => {
    brain.getProfile();
    return run(state.storage.sql);
  });
}

const files = (sql: SqlStorage) => sql.exec<{ path: string; kind: string; frontmatter: string; body: string; updated_at: string }>("SELECT * FROM files ORDER BY path").toArray();
const links = (sql: SqlStorage) => sql.exec<{ src: string; dst: string; kind: string }>("SELECT * FROM links ORDER BY src, dst").toArray();
const body = (sql: SqlStorage, path: string) => sql.exec<{ body: string }>("SELECT body FROM files WHERE path = ?", path).one().body;

describe("splitLearned and replaceAbout", () => {
  const learnedBody = "# About me\n\nLoves a toastie.\n\n## Learned while cooking\n\n- Hates coriander ([[sessions/s1]])\n- Owns one pan ([[sessions/s2]])\n\n## Kit\n\n- a pan\n";

  it("splits the free text from the learned entries", () => {
    expect(splitLearned(learnedBody)).toEqual({ about: "# About me\n\nLoves a toastie.\n\n## Kit\n\n- a pan\n", learned: ["Hates coriander", "Owns one pan"] });
  });

  it("leaves a body with no learned section alone", () => {
    expect(splitLearned("# About me")).toEqual({ about: "# About me", learned: [] });
    expect(replaceAbout("# About me", "New text")).toBe("New text");
  });

  it("keeps the learned section when about is replaced, and a split then replace is stable", () => {
    const replaced = replaceAbout(learnedBody, "# About me\n\nNow with more cheese.");
    expect(replaced).toBe("# About me\n\nNow with more cheese.\n\n## Learned while cooking\n\n- Hates coriander ([[sessions/s1]])\n- Owns one pan ([[sessions/s2]])\n");
    const { about } = splitLearned(learnedBody);
    expect(replaceAbout(replaceAbout(learnedBody, about), about)).toBe(replaceAbout(learnedBody, about));
    expect(splitLearned(replaceAbout(learnedBody, about))).toEqual(splitLearned(learnedBody));
  });

  it("drops a learned section sent in about, so it never duplicates", () => {
    expect(replaceAbout(learnedBody, learnedBody)).toBe(replaceAbout(learnedBody, splitLearned(learnedBody).about));
  });
});

describe("editSection", () => {
  it("adds a missing section at the end", () => {
    expect(editSection("# Toastie\n", "Cooks", addLines(["- one"]))).toBe("# Toastie\n\n## Cooks\n\n- one\n");
  });

  it("edits a section in place, leaving the rest alone", () => {
    const before = "# Toastie\n\n## Cooks\n\n- one\n\n## Swaps\n\n- ham\n";
    expect(editSection(before, "Cooks", addLines(["- one", "- two"]))).toBe("# Toastie\n\n## Cooks\n\n- one\n- two\n\n## Swaps\n\n- ham\n");
  });

  it("drops a section that ends up empty and leaves a body alone when nothing's added", () => {
    expect(editSection("# T\n\n## Cooks\n\n- [[s1]] x\n\n## Swaps\n\n- ham\n", "Cooks", replaceSessionLines("[[s1]]", []))).toBe("# T\n\n## Swaps\n\n- ham\n");
    expect(editSection("# T\n", "Cooks", addLines([]))).toBe("# T\n");
  });

  it("replaces only one session's lines", () => {
    const before = "## Next time\n\n- a ([[s1]])\n- b ([[s2]])\n";
    expect(editSection(before, "Next time", replaceSessionLines("[[s1]]", ["- c ([[s1]])"]))).toBe("## Next time\n\n- b ([[s2]])\n- c ([[s1]])\n");
  });
});

describe("dates", () => {
  it("names notes by the day in London", () => {
    expect(londonDate("2026-11-06T23:30:00Z")).toBe("2026-11-06");
    expect(londonDate("2026-07-06T23:30:00Z")).toBe("2026-07-07");
    expect(londonDay("2026-11-06T18:00:00Z")).toBe("6 November 2026");
    expect(sessionNotePath(session())).toBe("sessions/2026-11-06-fake-toastie-aaaaaaaa.md");
    expect(sessionNotePath(session({ recipe: null }))).toBe("sessions/2026-11-06-cook-aaaaaaaa.md");
  });
});

describe("writeReflection", () => {
  it("writes the session, recipe, topic notes and USER.md, all linked", async () => {
    await inVault("vault_write", (sql) => {
      const path = writeReflection(sql, session(), "2026-11-06T19:00:00Z");
      expect(path).toBe("sessions/2026-11-06-fake-toastie-aaaaaaaa.md");
      expect(files(sql).map((f) => [f.path, f.kind])).toEqual([
        ["USER.md", "user"],
        ["cuisines/british.md", "cuisine"],
        ["ingredients/bread.md", "ingredient"],
        ["ingredients/butter.md", "ingredient"],
        ["ingredients/red-leicester.md", "ingredient"],
        ["recipes/fake-toastie.md", "recipe"],
        [path, "session"],
        ["techniques/toasting.md", "technique"],
      ]);

      const sessionNote = body(sql, path);
      for (const text of [
        "# Fake Toastie, 6 November 2026",
        "Recipe: [[recipes/fake-toastie|Fake Toastie]]",
        "Rating: 4/5",
        "Cuisine: [[cuisines/british|british]]",
        "Golden and gooey.",
        "## What worked\n\n- Buttering edge to edge",
        "## What didn't\n\n- Lower the heat a touch",
        "## Swaps\n\n- red leicester instead of cheddar: Melted well",
        "## Learned about the cook\n\n- Hates coriander",
        "- [[ingredients/red-leicester|red leicester]]",
        "## Cook's notes\n\nNext time, more butter.",
      ]) {
        expect(sessionNote).toContain(text);
      }

      const recipeNote = body(sql, "recipes/fake-toastie.md");
      expect(recipeNote).toContain("# Fake Toastie\n\nSource: https://example.com/sous/fake-toastie");
      expect(recipeNote).toContain("## Cooks\n\n- [[sessions/2026-11-06-fake-toastie-aaaaaaaa]] 6 November 2026, 4/5: Golden and gooey.");
      expect(recipeNote).toContain("## Next time\n\n- Lower the heat a touch ([[sessions/2026-11-06-fake-toastie-aaaaaaaa]])");
      expect(recipeNote).toContain("## Ingredients\n\n- [[ingredients/bread|bread]]\n- [[ingredients/red-leicester|red leicester]]\n- [[ingredients/butter|butter]]");
      expect(JSON.parse(sql.exec<{ frontmatter: string }>("SELECT frontmatter FROM files WHERE path = 'recipes/fake-toastie.md'").one().frontmatter)).toEqual({
        recipe_id: "recipe-1",
        title: "Fake Toastie",
        times_cooked: 1,
        last_cooked: "2026-11-06",
      });

      expect(body(sql, "ingredients/bread.md")).toBe(
        "# bread\n\n## Cooked in\n\n- [[sessions/2026-11-06-fake-toastie-aaaaaaaa]] in [[recipes/fake-toastie|Fake Toastie]], 6 November 2026, 4/5\n",
      );
      expect(body(sql, "USER.md")).toContain("## Learned while cooking\n\n- Hates coriander ([[sessions/2026-11-06-fake-toastie-aaaaaaaa]])");

      expect(links(sql)).toEqual(
        expect.arrayContaining([
          { src: path, dst: "recipes/fake-toastie.md", kind: "recipe" },
          { src: path, dst: "cuisines/british.md", kind: "cuisine" },
          { src: path, dst: "ingredients/butter.md", kind: "ingredient" },
          { src: "recipes/fake-toastie.md", dst: path, kind: "session" },
          { src: "recipes/fake-toastie.md", dst: "techniques/toasting.md", kind: "technique" },
          { src: "ingredients/bread.md", dst: path, kind: "session" },
          { src: "USER.md", dst: path, kind: "session" },
        ]),
      );
    });
  });

  it("changes nothing when it runs again with the same reflection", async () => {
    await inVault("vault_idempotent", (sql) => {
      writeReflection(sql, session(), "2026-11-06T19:00:00Z");
      const filesBefore = files(sql);
      const linksBefore = links(sql);
      writeReflection(sql, session(), "2026-11-06T20:00:00Z");
      expect(files(sql)).toEqual(filesBefore);
      expect(links(sql)).toEqual(linksBefore);
    });
  });

  it("replaces a session's lines when it's reflected on again differently", async () => {
    await inVault("vault_rerun", (sql) => {
      writeReflection(sql, session(), "2026-11-06T19:00:00Z");
      writeReflection(sql, session({ reflection: { ...reflection, summary: "Actually great.", failed: [], ingredients: ["bread"] } }), "2026-11-06T20:00:00Z");
      const recipeNote = body(sql, "recipes/fake-toastie.md");
      expect(recipeNote).toContain("4/5: Actually great.");
      expect(recipeNote).not.toContain("Golden and gooey.");
      expect(recipeNote).not.toContain("## Next time");
      expect(recipeNote.match(/\[\[sessions\//g)).toHaveLength(2);
    });
  });

  it("adds a second cook alongside the first and doesn't repeat a known preference", async () => {
    await inVault("vault_second", (sql) => {
      writeReflection(sql, session(), "2026-11-06T19:00:00Z");
      const second = session({
        id: "bbbbbbbb-2222-4222-8222-222222222222",
        started_at: "2026-11-07T12:00:00Z",
        notes: null,
        reflection: { ...reflection, rating: null, summary: "Better.", preferences: ["hates coriander", "Owns one pan"], ingredients: ["bread"], substitutions: [] },
      });
      const path = writeReflection(sql, second, "2026-11-07T13:00:00Z");

      const recipeNote = body(sql, "recipes/fake-toastie.md");
      expect(recipeNote).toContain("- [[sessions/2026-11-07-fake-toastie-bbbbbbbb]] 7 November 2026: Better.");
      expect(JSON.parse(sql.exec<{ frontmatter: string }>("SELECT frontmatter FROM files WHERE path = 'recipes/fake-toastie.md'").one().frontmatter)).toMatchObject({
        times_cooked: 2,
        last_cooked: "2026-11-07",
      });
      expect(body(sql, "ingredients/bread.md").match(/^- /gm)).toHaveLength(2);
      expect(body(sql, path)).toContain("Rating: not rated");
      expect(body(sql, path)).not.toContain("Cook's notes");

      const learned = body(sql, "USER.md").split("## Learned while cooking")[1];
      expect(learned.match(/coriander/gi)).toHaveLength(1);
      expect(learned).toContain("- Owns one pan ([[sessions/2026-11-07-fake-toastie-bbbbbbbb]])");
    });
  });

  it("keeps what's already in a recipe note", async () => {
    await inVault("vault_existing", (sql) => {
      sql.exec(
        "INSERT INTO files (path, kind, frontmatter, body, updated_at) VALUES ('recipes/fake-toastie.md', 'recipe', ?, ?, '2026-11-01T00:00:00Z')",
        JSON.stringify({ tags: ["lunch"] }),
        "# Fake Toastie\n\nBest with sourdough, see [[ingredients/sourdough]].\n",
      );
      writeReflection(sql, session(), "2026-11-06T19:00:00Z");
      expect(body(sql, "recipes/fake-toastie.md")).toMatch(/^# Fake Toastie\n\nBest with sourdough, see \[\[ingredients\/sourdough\]\]\.\n\n## Cooks/);
      expect(JSON.parse(sql.exec<{ frontmatter: string }>("SELECT frontmatter FROM files WHERE path = 'recipes/fake-toastie.md'").one().frontmatter)).toMatchObject({ tags: ["lunch"] });
      expect(links(sql)).toContainEqual({ src: "recipes/fake-toastie.md", dst: "ingredients/sourdough.md", kind: "ingredient" });
    });
  });

  it("still files a cook whose recipe has gone", async () => {
    await inVault("vault_norecipe", (sql) => {
      const path = writeReflection(sql, session({ recipe: null }), "2026-11-06T19:00:00Z");
      expect(path).toBe("sessions/2026-11-06-cook-aaaaaaaa.md");
      expect(body(sql, path)).toMatch(/^# A cook, 6 November 2026\n\nRating: 4\/5/);
      expect(files(sql).some((f) => f.kind === "recipe")).toBe(false);
      expect(body(sql, "ingredients/bread.md")).toContain("- [[sessions/2026-11-06-cook-aaaaaaaa]], 6 November 2026, 4/5");
    });
  });
});

describe("rebuildLinks", () => {
  it("rebuilds the table from the wikilinks, dropping stale and self links", async () => {
    await inVault("vault_links", (sql) => {
      const file = (path: string, kind: string, text: string) =>
        sql.exec("INSERT INTO files (path, kind, body, updated_at) VALUES (?, ?, ?, '2026-11-06T00:00:00Z')", path, kind, text);
      file("recipes/a.md", "recipe", "Uses [[ingredients/egg]] and [[ingredients/egg|eggs]], see [[recipes/a]] and [[elsewhere/thing]].");
      file("ingredients/egg.md", "ingredient", "No links.");
      sql.exec("INSERT INTO links (src, dst, kind) VALUES ('ingredients/egg.md', 'recipes/gone.md', 'recipe')");
      rebuildLinks(sql);
      expect(links(sql)).toEqual([
        { src: "recipes/a.md", dst: "elsewhere/thing.md", kind: "note" },
        { src: "recipes/a.md", dst: "ingredients/egg.md", kind: "ingredient" },
      ]);
      rebuildLinks(sql);
      expect(links(sql)).toHaveLength(2);
    });
  });
});
