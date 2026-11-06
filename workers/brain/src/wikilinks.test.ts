import { describe, expect, it } from "vitest";
import { linkKind, parseWikilinks, resolveLink, wikilink } from "./wikilinks";

describe("parseWikilinks", () => {
  it("finds plain, labelled and heading links, once each, in order", () => {
    const body = [
      "Made [[recipes/fake-toastie]] with [[ingredients/cheddar|mature cheddar]].",
      "See [[sessions/2026-11-06-abc#What worked]] and [[recipes/fake-toastie.md]] again.",
      "Embedded ![[cuisines/british]].",
    ].join("\n");
    expect(parseWikilinks(body)).toEqual(["recipes/fake-toastie.md", "ingredients/cheddar.md", "sessions/2026-11-06-abc.md", "cuisines/british.md"]);
  });

  it("ignores empty, same-note and broken links", () => {
    expect(parseWikilinks("[[]] [[#Heading]] [[ ]] [[half [single] [[two\nlines]]")).toEqual([]);
  });

  it("returns nothing for a body without links", () => {
    expect(parseWikilinks("Just a toastie.")).toEqual([]);
  });
});

describe("resolveLink", () => {
  it("adds .md unless the target has an extension, and drops a leading slash", () => {
    expect(resolveLink("USER")).toBe("USER.md");
    expect(resolveLink(" /recipes/toastie ")).toBe("recipes/toastie.md");
    expect(resolveLink("photos/toastie.png")).toBe("photos/toastie.png");
    expect(resolveLink("  ")).toBeNull();
  });
});

describe("linkKind", () => {
  it("names a link by the kind of note it points at", () => {
    expect(linkKind("recipes/toastie.md")).toBe("recipe");
    expect(linkKind("sessions/s.md")).toBe("session");
    expect(linkKind("ingredients/cheddar.md")).toBe("ingredient");
    expect(linkKind("techniques/toasting.md")).toBe("technique");
    expect(linkKind("cuisines/british.md")).toBe("cuisine");
    expect(linkKind("USER.md")).toBe("user");
    expect(linkKind("MEMORY.md")).toBe("memory");
    expect(linkKind("elsewhere/thing.md")).toBe("note");
  });
});

describe("wikilink", () => {
  it("writes a link the parser reads back", () => {
    expect(wikilink("ingredients/cheddar.md")).toBe("[[ingredients/cheddar]]");
    expect(wikilink("ingredients/cheddar.md", "cheddar")).toBe("[[ingredients/cheddar|cheddar]]");
    expect(parseWikilinks(wikilink("ingredients/cheddar.md", "cheddar"))).toEqual(["ingredients/cheddar.md"]);
  });
});
