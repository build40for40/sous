import { describe, expect, it } from "vitest";
import { parseSharedText } from "./links";
import { findRecipeLink } from "./sources";

describe("parseSharedText", () => {
  it("reduces every form of an Instagram post link to its shortcode", async () => {
    for (const text of [
      "https://www.instagram.com/reel/DTwZpo5DNVr/?igsh=MWQ1ZGUxMzBkMA==",
      "https://instagram.com/reels/DTwZpo5DNVr",
      "https://www.instagram.com/feelgoodfoodie/reel/DTwZpo5DNVr/",
      "Check out this reel by @feelgoodfoodie https://www.instagram.com/reel/DTwZpo5DNVr/?utm_source=ig_web_copy_link",
    ]) {
      expect(await parseSharedText(text)).toEqual({ kind: "instagram", key: "ig:DTwZpo5DNVr", shortcode: "DTwZpo5DNVr", url: "https://www.instagram.com/reel/DTwZpo5DNVr/" });
    }
    expect(await parseSharedText("https://www.instagram.com/p/DdoQSMHtasl/")).toMatchObject({ key: "ig:DdoQSMHtasl", url: "https://www.instagram.com/p/DdoQSMHtasl/" });
  });

  it("refuses Instagram links that aren't a post", async () => {
    expect(await parseSharedText("https://www.instagram.com/feelgoodfoodie/")).toBeNull();
    expect(await parseSharedText("https://www.instagram.com/")).toBeNull();
  });

  it("keeps other web pages, minus tracking", async () => {
    const link = await parseSharedText("https://feelgoodfoodie.net/recipe/stuffed-onions/?utm_source=ig&fbclid=x&page=2#comments");
    expect(link).toMatchObject({ kind: "web", url: "https://feelgoodfoodie.net/recipe/stuffed-onions/?page=2" });
    expect(link?.key).toMatch(/^web:[0-9a-f]{64}$/);
  });

  it("needs a link", async () => {
    expect(await parseSharedText("no link here")).toBeNull();
    expect(await parseSharedText("ftp://example.com/x")).toBeNull();
  });
});

describe("findRecipeLink", () => {
  it("finds the creator's recipe page and skips link-in-bio and shop links", () => {
    expect(findRecipeLink("Comment RECIPE! https://linktr.ee/x and https://feelgoodfoodie.net/recipe/stuffed-onions/.")).toBe("https://feelgoodfoodie.net/recipe/stuffed-onions/");
    expect(findRecipeLink("Shop my kitchen https://amzn.to/abc")).toBeNull();
    expect(findRecipeLink("No links")).toBeNull();
  });
});
