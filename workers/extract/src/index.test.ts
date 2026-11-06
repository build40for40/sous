import { env, exports } from "cloudflare:workers";
import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BASE_PATH } from "./http";
import type { Share } from "./inbox";
import { USER_AGENT } from "./sources";
import { claudeOutcome, claudeRecipe, embedPage, embedUrl, mockWeb, recipePage, signToken, type Web } from "./testing";

let web: Web;
let n = 0;
let ALICE = "";
let BOB = "";
/** Storage persists between tests, so every test gets its own users, posts, pages and images. */
const S = (code: string) => `${code}${n}`;
beforeEach(() => {
  web = mockWeb();
  n += 1;
  ALICE = `user_alice${n}`;
  BOB = `user_bob${n}`;
});
afterEach(() => {
  vi.restoreAllMocks();
});

async function call(path: string, { user = ALICE as string | null, method = "GET", body, token }: { user?: string | null; method?: string; body?: unknown; token?: string } = {}) {
  const headers = new Headers();
  const bearer = token ?? (user ? await signToken(user) : undefined);
  if (bearer) headers.set("Authorization", `Bearer ${bearer}`);
  if (body !== undefined) headers.set("Content-Type", "application/json");
  return exports.default.fetch(`https://build40for40.com${BASE_PATH}/shares${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
}

async function share(url: string, user = ALICE): Promise<{ status: number; body: Share & { duplicate?: boolean } }> {
  const response = await call("", { user, method: "POST", body: { url } });
  return { status: response.status, body: (await response.json()) as Share & { duplicate?: boolean } };
}

const runPost = (key: string) => runDurableObjectAlarm(env.POST_EXTRACTION.get(env.POST_EXTRACTION.idFromName(key)));
const brainRecipes = (user: string) => (env.USER_BRAIN.get(env.USER_BRAIN.idFromName(user)) as any).listRecipes() as Promise<any[]>;
const getShare = async (id: string, user = ALICE) => (await (await call(`/${id}`, { user })).json()) as Share;

const COOKIES = "2-ingredient banana coconut cookies 🍪\nINGREDIENTS\n2 ripe bananas\n2 cups unsweetened shredded coconut\n½ cup chocolate chips\nINSTRUCTIONS\n1. Preheat to 350°F.\n2. Mash and mix.\n3. Bake 12-15 minutes until golden.";
// A tiny valid PNG.
const BASE_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABh6FO1AAAAABJRU5ErkJggg==";

/** A PNG made unique per test with a trailing byte, so its hash (and its post key) differs. */
let PNG = "";
beforeEach(() => {
  const bytes = Uint8Array.from(atob(BASE_PNG), (c) => c.charCodeAt(0));
  PNG = btoa(String.fromCharCode(...bytes, n % 256, Math.floor(n / 256)));
});

describe("auth and routing", () => {
  it("needs a WorkOS token", async () => {
    const response = await call("", { user: null });
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "sign_in_required" });
  });

  it("only answers under /shares", async () => {
    const response = await exports.default.fetch(`https://build40for40.com${BASE_PATH}/recipes`);
    expect(response.status).toBe(404);
  });

  it("rejects links that aren't a post or a web page", async () => {
    expect((await share("not a link")).status).toBe(422);
    expect((await share("https://www.instagram.com/feelgoodfoodie/")).status).toBe(422);
  });
});

describe("sharing an Instagram post with the recipe in the caption", () => {
  it("reads the caption once, asks Claude, and saves the recipe into the user's brain", async () => {
    web.pages.set(embedUrl(S("DTwZpo5DNVr")), embedPage("feelgoodfoodie", COOKIES));
    web.claude.push(claudeRecipe());

    const { status, body } = await share(`https://www.instagram.com/reel/${S("DTwZpo5DNVr")}/?igsh=MWQ1ZGUxMzBkMA==`);
    expect(status).toBe(202);
    expect(body).toMatchObject({ status: "reading", kind: "link", url: `https://www.instagram.com/reel/${S("DTwZpo5DNVr")}/` });

    expect(await runPost(`ig:${S("DTwZpo5DNVr")}`)).toBe(true);
    const done = await getShare(body.id);
    expect(done).toMatchObject({ status: "saved", title: "Banana Coconut Cookies", creator: "feelgoodfoodie", source_used: "caption", completeness: "complete" });

    const [saved] = await brainRecipes(ALICE);
    expect(saved.id).toBe(done.recipe_id);
    expect(saved).toMatchObject({ title: "Banana Coconut Cookies", source_url: `https://www.instagram.com/reel/${S("DTwZpo5DNVr")}/`, servings: 12, times: { prep_minutes: 10, cook_minutes: 15 } });
    expect(saved.ingredients[0]).toEqual({ name: "ripe bananas", quantity: 2 });
    expect(saved.ingredients[2]).toEqual({ name: "chocolate chips", quantity: 0.5, unit: "cup", note: "optional" });
    expect(saved.steps[2]).toEqual({ text: "Bake until set.", done_cue: "the coconut is golden", duration_seconds: 900 });

    // One honest request to Instagram's embed page, and the caption went to Claude as data.
    expect(web.requests).toEqual([[embedUrl(S("DTwZpo5DNVr")), USER_AGENT]]);
    const prompt = web.claudeRequests[0];
    expect(prompt.model).toBe("claude-opus-5-5");
    expect(prompt.fallbacks).toBe("default");
    expect(prompt.messages[0].content[0].text).toContain("<caption>\n2-ingredient banana coconut cookies");
    expect(prompt.messages[0].content[0].text).toContain("Creator: @feelgoodfoodie");
    expect(prompt.messages[0].content[0].text).not.toContain("View all");
  });

  it("gives a second person the same post straight away, without reading it again", async () => {
    web.pages.set(embedUrl(S("DTwZpo5DNVr")), embedPage("feelgoodfoodie", COOKIES));
    web.claude.push(claudeRecipe());
    await share(`https://www.instagram.com/reel/${S("DTwZpo5DNVr")}/`);
    await runPost(`ig:${S("DTwZpo5DNVr")}`);

    const { status, body } = await share(`https://instagram.com/p/${S("DTwZpo5DNVr")}`, BOB);
    expect(status).toBe(202);
    expect(body.status).toBe("saved");
    expect(await brainRecipes(BOB)).toHaveLength(1);
    expect(web.claudeRequests).toHaveLength(1);
    expect(web.requests).toHaveLength(1);
  });

  it("treats the same person sharing the same post twice as a duplicate", async () => {
    web.pages.set(embedUrl(S("DTwZpo5DNVr")), embedPage("feelgoodfoodie", COOKIES));
    const first = await share(`https://www.instagram.com/reel/${S("DTwZpo5DNVr")}/?igsh=abc`);
    const again = await share(`https://www.instagram.com/reel/${S("DTwZpo5DNVr")}/?igsh=xyz`);
    expect(again.status).toBe(200);
    expect(again.body).toMatchObject({ id: first.body.id, duplicate: true });
    expect((await (await call("")).json() as { shares: Share[] }).shares).toHaveLength(1);
  });
});

describe("sharing a post whose caption links the creator's recipe page", () => {
  it("reads the page's recipe data and gives it to Claude alongside the caption", async () => {
    const caption = `Comment RECIPE for these stuffed onions! https://feelgoodfoodie.net/recipe/stuffed-onions-${n}/`;
    web.pages.set(embedUrl(S("DVKgkKPDCjr")), embedPage("feelgoodfoodie", caption));
    web.pages.set(`https://feelgoodfoodie.net/recipe/stuffed-onions-${n}/`, recipePage("Stuffed Onions", ["4 large onions", "1 lb ground beef"], ["Par-boil the onions.", "Stuff and simmer."]));
    web.claude.push(claudeRecipe({ source_used: "recipe_page", recipe: { ...claudeRecipe().recipe, title: "Stuffed Onions" } }));

    const { body } = await share(`https://www.instagram.com/reel/${S("DVKgkKPDCjr")}/`);
    await runPost(`ig:${S("DVKgkKPDCjr")}`);

    const text = web.claudeRequests[0].messages[0].content[0].text as string;
    expect(text).toContain(`<recipe_page url="https://feelgoodfoodie.net/recipe/stuffed-onions-${n}/">`);
    expect(text).toContain("- 4 large onions");
    expect(text).toContain("- Par-boil the onions.");
    expect(await getShare(body.id)).toMatchObject({ status: "saved", source_used: "recipe_page" });
  });

  it("carries on with the caption if the recipe page won't open", async () => {
    web.pages.set(embedUrl(S("DVKgkKPDCjr")), embedPage("feelgoodfoodie", `Recipe https://blocked.example/onions-${n}`));
    web.pages.set(`https://blocked.example/onions-${n}`, 403);
    web.claude.push(claudeOutcome("needs_screenshot", "The recipe is on a page Sous couldn't open."));

    const { body } = await share(`https://www.instagram.com/reel/${S("DVKgkKPDCjr")}/`);
    await runPost(`ig:${S("DVKgkKPDCjr")}`);
    expect(web.claudeRequests[0].messages[0].content[0].text).toContain("couldn't be opened");
    expect(await getShare(body.id)).toMatchObject({ status: "needs_screenshot" });
  });
});

describe("posts Sous can't make a recipe from by itself", () => {
  it("asks for a screenshot when the recipe is in the comments, then saves it from the screenshot", async () => {
    web.pages.set(embedUrl(S("DdoQSMHtasl")), embedPage("kierans__kitchen", "Minted Lamb Hotpot 🍷 Recipe in comments 👇"));
    web.claude.push(claudeOutcome("needs_screenshot", "The recipe is in the comments."));
    const { body } = await share(`https://www.instagram.com/p/${S("DdoQSMHtasl")}/`);
    await runPost(`ig:${S("DdoQSMHtasl")}`);
    expect(await getShare(body.id)).toMatchObject({ status: "needs_screenshot", reason: "The recipe is in the comments.", recipe_id: null });
    expect(await brainRecipes(ALICE)).toHaveLength(0);

    web.claude.push(claudeRecipe({ source_used: "screenshot", recipe: { ...claudeRecipe().recipe, title: "Minted Lamb Hotpot" } }));
    const response = await call(`/${body.id}/screenshot`, { method: "POST", body: { image: { media_type: "image/png", data: PNG } } });
    expect(response.status).toBe(202);
    const shot = (await response.json()) as Share;
    expect(shot).toMatchObject({ id: body.id, kind: "screenshot", status: "reading" });

    const imageKey = `img:${await sha256Base64(PNG)}`;
    await runPost(imageKey);

    expect(web.claudeRequests[1].messages[0].content[1]).toMatchObject({ type: "image", source: { type: "base64", media_type: "image/png", data: PNG } });
    expect(await getShare(body.id)).toMatchObject({ status: "saved", title: "Minted Lamb Hotpot", source_used: "screenshot" });
    const [saved] = await brainRecipes(ALICE);
    expect(saved.source_url).toBe(`https://www.instagram.com/p/${S("DdoQSMHtasl")}/`);
  });

  it("says when a post has no recipe, and skips meal-prep plans", async () => {
    web.pages.set(embedUrl(S("DfPrpAzOmfI")), embedPage("amauryguichon", "Blueberries! 🫐 #chocolate"));
    web.pages.set(embedUrl(S("DfHya3HsegL")), embedPage("barefoodtim", "comment PLAN for this week's 5 recipes"));
    web.claude.push(claudeOutcome("no_recipe", "This is a chocolate showpiece with no recipe."), claudeOutcome("meal_prep", "A weekly plan of five recipes sent by DM."));

    const showpiece = await share(`https://www.instagram.com/reel/${S("DfPrpAzOmfI")}/`);
    await runPost(`ig:${S("DfPrpAzOmfI")}`);
    const plan = await share(`https://www.instagram.com/reel/${S("DfHya3HsegL")}/`);
    await runPost(`ig:${S("DfHya3HsegL")}`);

    expect(await getShare(showpiece.body.id)).toMatchObject({ status: "no_recipe", reason: "This is a chocolate showpiece with no recipe." });
    expect(await getShare(plan.body.id)).toMatchObject({ status: "skipped" });
    expect(await brainRecipes(ALICE)).toHaveLength(0);
  });

  it("asks for a screenshot without calling Claude when the post can't be opened", async () => {
    web.pages.set(embedUrl(S("PrivatePost1")), "<html><body>This content isn't available</body></html>");
    const { body } = await share(`https://www.instagram.com/p/${S("PrivatePost1")}/`);
    await runPost(`ig:${S("PrivatePost1")}`);
    expect(await getShare(body.id)).toMatchObject({ status: "needs_screenshot", reason: "Sous couldn't open this post. It may be private or deleted." });
    expect(web.claudeRequests).toHaveLength(0);
  });

  it("turns a recipe Claude couldn't fill in into a screenshot request rather than an empty recipe", async () => {
    web.pages.set(embedUrl(S("SpokenOnly1")), embedPage("nick.digiovanni", "3-Michelin Star Potatoes"));
    web.claude.push(claudeRecipe({ recipe: { ...claudeRecipe().recipe, ingredients: [], steps: [] } }));
    const { body } = await share(`https://www.instagram.com/reel/${S("SpokenOnly1")}/`);
    await runPost(`ig:${S("SpokenOnly1")}`);
    expect(await getShare(body.id)).toMatchObject({ status: "needs_screenshot" });
    expect(await brainRecipes(ALICE)).toHaveLength(0);
  });
});

describe("when Instagram or Claude is struggling", () => {
  it("retries later when Instagram rate limits, then succeeds", async () => {
    web.pages.set(embedUrl(S("DTwZpo5DNVr")), 429);
    const { body } = await share(`https://www.instagram.com/reel/${S("DTwZpo5DNVr")}/`);
    await runPost(`ig:${S("DTwZpo5DNVr")}`);
    expect(await getShare(body.id)).toMatchObject({ status: "reading" });
    const stub = env.POST_EXTRACTION.get(env.POST_EXTRACTION.idFromName(`ig:${S("DTwZpo5DNVr")}`));
    const retryAt = await runInDurableObject(stub, (_post, state) => state.storage.getAlarm());
    expect(retryAt).toBeGreaterThan(Date.now());

    web.pages.set(embedUrl(S("DTwZpo5DNVr")), embedPage("feelgoodfoodie", COOKIES));
    web.claude.push(claudeRecipe());
    await runPost(`ig:${S("DTwZpo5DNVr")}`);
    expect(await getShare(body.id)).toMatchObject({ status: "saved" });
  });

  it("retries when Claude is overloaded", async () => {
    web.pages.set(embedUrl(S("DTwZpo5DNVr")), embedPage("feelgoodfoodie", COOKIES));
    web.claude.push(529, 529, claudeRecipe());
    const { body } = await share(`https://www.instagram.com/reel/${S("DTwZpo5DNVr")}/`);
    await runPost(`ig:${S("DTwZpo5DNVr")}`);
    expect(await getShare(body.id)).toMatchObject({ status: "reading" });
    await runPost(`ig:${S("DTwZpo5DNVr")}`);
    expect(await getShare(body.id)).toMatchObject({ status: "saved" });
  });

  it("returns 503 without the Anthropic key", async () => {
    const original = env.ANTHROPIC_API_KEY;
    (env as { ANTHROPIC_API_KEY: string }).ANTHROPIC_API_KEY = "";
    try {
      expect((await share(`https://www.instagram.com/reel/${S("DTwZpo5DNVr")}/`)).status).toBe(503);
    } finally {
      (env as { ANTHROPIC_API_KEY: string }).ANTHROPIC_API_KEY = original;
    }
  });
});

describe("sharing a recipe web page or a screenshot directly", () => {
  it("reads a recipe site's recipe data", async () => {
    web.pages.set(`https://www.halfbakedharvest.com/pot-roast-stroganoff-${n}/`, recipePage("Easy Pot Roast Stroganoff", ["3 lb chuck roast"], ["Sear the beef."]));
    web.claude.push(claudeRecipe({ source_used: "recipe_page", recipe: { ...claudeRecipe().recipe, title: "Easy Pot Roast Stroganoff" } }));
    const { body } = await share(`Look at this https://www.halfbakedharvest.com/pot-roast-stroganoff-${n}/?utm_source=ig`);
    expect(body.url).toBe(`https://www.halfbakedharvest.com/pot-roast-stroganoff-${n}/`);
    await runPost(`web:${await sha256Text(body.url!)}`);
    expect(await getShare(body.id)).toMatchObject({ status: "saved", source_used: "recipe_page" });
  });

  it("says so when a web page has no recipe data, without calling Claude", async () => {
    web.pages.set(`https://example.com/blog-post-${n}`, "<html><body>Just a blog</body></html>");
    const { body } = await share(`https://example.com/blog-post-${n}`);
    await runPost(`web:${await sha256Text(body.url!)}`);
    expect(await getShare(body.id)).toMatchObject({ status: "needs_screenshot", reason: "Sous couldn't find a recipe on that page." });
    expect(web.claudeRequests).toHaveLength(0);
  });

  it("takes a screenshot on its own", async () => {
    web.claude.push(claudeRecipe({ source_used: "screenshot" }));
    const response = await call("", { method: "POST", body: { image: { media_type: "image/png", data: PNG } } });
    expect(response.status).toBe(202);
    const body = (await response.json()) as Share;
    await runPost(`img:${await sha256Base64(PNG)}`);
    expect(await getShare(body.id)).toMatchObject({ status: "saved", kind: "screenshot", url: null });
  });

  it("rejects images that aren't images or are too big", async () => {
    expect((await call("", { method: "POST", body: { image: { media_type: "application/pdf", data: PNG } } })).status).toBe(400);
    const big = btoa("x".repeat(1_950_000));
    expect((await call("", { method: "POST", body: { image: { media_type: "image/jpeg", data: big } } })).status).toBe(413);
  });
});

describe("the share list", () => {
  it("lists, shows and forgets shares, per user", async () => {
    web.pages.set(embedUrl(S("DTwZpo5DNVr")), embedPage("feelgoodfoodie", COOKIES));
    const { body } = await share(`https://www.instagram.com/reel/${S("DTwZpo5DNVr")}/`);
    expect(((await (await call("")).json()) as { shares: Share[] }).shares.map((s) => s.id)).toEqual([body.id]);
    expect(((await (await call("", { user: BOB })).json()) as { shares: Share[] }).shares).toEqual([]);
    expect((await call(`/${body.id}`, { user: BOB })).status).toBe(404);
    expect((await call(`/${body.id}`, { method: "DELETE" })).status).toBe(204);
    expect((await call(`/${body.id}`)).status).toBe(404);
  });

  it("caps shares per day", async () => {
    (env as { SOUS_DAILY_SHARE_LIMIT: string }).SOUS_DAILY_SHARE_LIMIT = "2";
    try {
      expect((await share(`https://www.instagram.com/p/${S("AAAAAA1")}/`)).status).toBe(202);
      expect((await share(`https://www.instagram.com/p/${S("AAAAAA2")}/`)).status).toBe(202);
      const third = await share(`https://www.instagram.com/p/${S("AAAAAA3")}/`);
      expect(third.status).toBe(429);
    } finally {
      (env as { SOUS_DAILY_SHARE_LIMIT: string }).SOUS_DAILY_SHARE_LIMIT = "50";
    }
  });
});

async function sha256Text(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Base64(data: string): Promise<string> {
  const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

describe("review fixes: failures are never cached (#195)", () => {
  it("reads a post again for the next person after it looked private", async () => {
    web.pages.set(embedUrl(S("Flaky01")), "<html><body>Log in to see this</body></html>");
    const first = await share(`https://www.instagram.com/p/${S("Flaky01")}/`);
    await runPost(`ig:${S("Flaky01")}`);
    expect(await getShare(first.body.id)).toMatchObject({ status: "needs_screenshot" });

    web.pages.set(embedUrl(S("Flaky01")), embedPage("feelgoodfoodie", COOKIES));
    web.claude.push(claudeRecipe());
    const second = await share(`https://www.instagram.com/p/${S("Flaky01")}/`, BOB);
    expect(second.body.status).toBe("reading");
    await runPost(`ig:${S("Flaky01")}`);
    expect(await getShare(second.body.id, BOB)).toMatchObject({ status: "saved" });
  });

  it("gives up after five attempts, then the same person sharing again tries afresh", async () => {
    web.pages.set(embedUrl(S("Down01")), 429);
    const { body } = await share(`https://www.instagram.com/reel/${S("Down01")}/`);
    for (let i = 0; i < 5; i++) await runPost(`ig:${S("Down01")}`);
    expect(await getShare(body.id)).toMatchObject({ status: "needs_screenshot", reason: "Sous couldn't read this right now. Share it again later, or share a screenshot of the recipe." });

    web.pages.set(embedUrl(S("Down01")), embedPage("feelgoodfoodie", COOKIES));
    web.claude.push(claudeRecipe());
    const again = await share(`https://www.instagram.com/reel/${S("Down01")}/`);
    expect(again.status).toBe(202);
    expect(again.body).toMatchObject({ id: body.id, status: "reading" });
    await runPost(`ig:${S("Down01")}`);
    expect(await getShare(body.id)).toMatchObject({ status: "saved" });
  });

  it("doesn't cache an answer made without a recipe page that wouldn't open", async () => {
    web.pages.set(embedUrl(S("Page01")), embedPage("feelgoodfoodie", `Recipe https://flaky.example/r-${n}`));
    web.pages.set(`https://flaky.example/r-${n}`, 503);
    web.claude.push(claudeOutcome("needs_screenshot", "The recipe is on a page Sous couldn't open."));
    await share(`https://www.instagram.com/reel/${S("Page01")}/`);
    await runPost(`ig:${S("Page01")}`);

    web.pages.set(`https://flaky.example/r-${n}`, recipePage("Onions", ["4 onions"], ["Stuff them."]));
    web.claude.push(claudeRecipe({ source_used: "recipe_page" }));
    const bob = await share(`https://www.instagram.com/reel/${S("Page01")}/`, BOB);
    expect(bob.body.status).toBe("reading");
    await runPost(`ig:${S("Page01")}`);
    expect(await getShare(bob.body.id, BOB)).toMatchObject({ status: "saved", source_used: "recipe_page" });
  });

  it("still caches Claude's answer when every source was read", async () => {
    web.pages.set(embedUrl(S("Show01")), embedPage("amauryguichon", "Blueberries!"));
    web.claude.push(claudeOutcome("no_recipe", "A showpiece."));
    await share(`https://www.instagram.com/reel/${S("Show01")}/`);
    await runPost(`ig:${S("Show01")}`);
    const bob = await share(`https://www.instagram.com/reel/${S("Show01")}/`, BOB);
    expect(bob.body.status).toBe("no_recipe");
    expect(web.claudeRequests).toHaveLength(1);
  });
});

describe("review fixes: screenshot rescue only when needed (#196)", () => {
  it("refuses a screenshot for a share that's already saved, without a second recipe", async () => {
    web.pages.set(embedUrl(S("Saved1")), embedPage("feelgoodfoodie", COOKIES));
    web.claude.push(claudeRecipe());
    const { body } = await share(`https://www.instagram.com/reel/${S("Saved1")}/`);
    await runPost(`ig:${S("Saved1")}`);
    const response = await call(`/${body.id}/screenshot`, { method: "POST", body: { image: { media_type: "image/png", data: PNG } } });
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: "screenshot_not_needed" });
    expect(await brainRecipes(ALICE)).toHaveLength(1);
    expect(web.claudeRequests).toHaveLength(1);
  });

  it("counts screenshots toward the daily limit", async () => {
    (env as { SOUS_DAILY_SHARE_LIMIT: string }).SOUS_DAILY_SHARE_LIMIT = "2";
    try {
      web.pages.set(embedUrl(S("Cmnts1")), embedPage("kierans__kitchen", "Recipe in comments"));
      web.claude.push(claudeOutcome("needs_screenshot", "The recipe is in the comments."), claudeOutcome("needs_screenshot", "That screenshot has no recipe."));
      const { body } = await share(`https://www.instagram.com/p/${S("Cmnts1")}/`); // read 1
      await runPost(`ig:${S("Cmnts1")}`);
      const shot = await call(`/${body.id}/screenshot`, { method: "POST", body: { image: { media_type: "image/png", data: PNG } } }); // read 2
      expect(shot.status).toBe(202);
      await runPost(`img:${await sha256Base64(PNG)}`);
      expect(await getShare(body.id)).toMatchObject({ status: "needs_screenshot" });
      const third = await call(`/${body.id}/screenshot`, { method: "POST", body: { image: { media_type: "image/png", data: BASE_PNG } } });
      expect(third.status).toBe(429);
    } finally {
      (env as { SOUS_DAILY_SHARE_LIMIT: string }).SOUS_DAILY_SHARE_LIMIT = "50";
    }
  });
});

describe("review fixes: account deletion (#197)", () => {
  it("DELETE /shares forgets every share for that user only", async () => {
    web.pages.set(embedUrl(S("Wipe01")), embedPage("feelgoodfoodie", COOKIES));
    await share(`https://www.instagram.com/reel/${S("Wipe01")}/`);
    await share(`https://www.instagram.com/reel/${S("Wipe01")}/`, BOB);
    expect((await call("", { method: "DELETE" })).status).toBe(204);
    expect(((await (await call("")).json()) as { shares: Share[] }).shares).toEqual([]);
    expect(((await (await call("", { user: BOB })).json()) as { shares: Share[] }).shares).toHaveLength(1);
  });
});
