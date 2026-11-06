/**
 * Reading what a shared link offers, with the lightest touch we can:
 *
 * - Instagram: one request to the post's public embed page, the same page Instagram
 *   serves to any website that embeds the post. That gives the creator and the full
 *   caption. No login, no video or audio download, no comments.
 * - Recipe pages (linked in a caption, or shared directly): the schema.org Recipe data
 *   recipe sites publish for search engines.
 *
 * Every request says it's Sous. We never pretend to be a browser or a crawler.
 */

export const USER_AGENT = "Sous/1.0 (+https://build40for40.com/sous)";
const TIMEOUT_MS = 15_000;
const MAX_PAGE_BYTES = 3 * 1024 * 1024;
const MAX_TEXT = 20_000;
const SKIP_LINK_HOSTS = /(^|\.)(instagram\.com|linktr\.ee|beacons\.ai|tiktok\.com|youtube\.com|youtu\.be|amzn\.to|amazon\.[a-z.]+|bit\.ly|shopmy\.us|liketk\.it)$/i;

export interface InstagramPost {
  creator: string | null;
  caption: string;
}

/** Why a source couldn't be read. `retry` means trying again later might work. */
export class SourceError extends Error {
  constructor(
    message: string,
    readonly retry: boolean,
  ) {
    super(message);
  }
}

async function get(url: string): Promise<string> {
  let response: Response;
  try {
    response = await fetch(url, {
      headers: { "User-Agent": USER_AGENT, Accept: "text/html,application/xhtml+xml", "Accept-Language": "en-GB,en;q=0.9" },
      redirect: "follow",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (e) {
    throw new SourceError(`Couldn't reach ${new URL(url).hostname}: ${(e as Error).message}`, true);
  }
  if (response.status === 429 || response.status >= 500) throw new SourceError(`${new URL(url).hostname} answered ${response.status}`, true);
  if (!response.ok) throw new SourceError(`${new URL(url).hostname} answered ${response.status}`, false);
  const text = await response.text();
  return text.length > MAX_PAGE_BYTES ? text.slice(0, MAX_PAGE_BYTES) : text;
}

/** The creator and full caption from the post's public embed page. */
export async function readInstagramPost(shortcode: string): Promise<InstagramPost> {
  const page = await get(`https://www.instagram.com/p/${encodeURIComponent(shortcode)}/embed/captioned/`);
  const caption = page.match(/class="Caption"[^>]*>([\s\S]*?)<\/div>/)?.[1];
  if (caption === undefined) {
    // Private, deleted, age-restricted, or Instagram changed the page.
    throw new SourceError("The post's caption isn't public", false);
  }
  const creator = caption.match(/class="CaptionUsername"[^>]*>([^<]+)</)?.[1]?.trim() ?? page.match(/class="UsernameText"[^>]*>([^<]+)</)?.[1]?.trim() ?? null;
  let text = decodeEntities(stripTags(caption.replace(/<br\s*\/?>/gi, "\n")));
  if (creator && text.trimStart().startsWith(creator)) text = text.trimStart().slice(creator.length);
  text = text.replace(/\s*View all [\d,]+ comments?\s*$/i, "").trim();
  return { creator, caption: text.slice(0, MAX_TEXT) };
}

/** The first link in a caption that could be the creator's recipe page. */
export function findRecipeLink(caption: string): string | null {
  for (const raw of caption.match(/https?:\/\/[^\s<>"')\]]+/gi) ?? []) {
    const link = raw.replace(/[.,!?]+$/, "");
    try {
      if (!SKIP_LINK_HOSTS.test(new URL(link).hostname)) return link;
    } catch {
      // not a URL after all
    }
  }
  return null;
}

/** The schema.org Recipe on a page, as compact text for Claude, or null if the page has none. */
export async function readRecipePage(url: string): Promise<string | null> {
  const page = await get(url);
  for (const block of page.matchAll(/<script[^>]*application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi)) {
    let data: unknown;
    try {
      data = JSON.parse(block[1].trim());
    } catch {
      continue;
    }
    for (const node of walk(data)) {
      const types = ([] as unknown[]).concat(node["@type"]);
      if (types.includes("Recipe")) return recipeText(node).slice(0, MAX_TEXT);
    }
  }
  return null;
}

function* walk(data: unknown): Generator<Record<string, unknown>> {
  if (Array.isArray(data)) for (const item of data) yield* walk(item);
  else if (data && typeof data === "object") {
    yield data as Record<string, unknown>;
    for (const value of Object.values(data)) yield* walk(value);
  }
}

function recipeText(r: Record<string, unknown>): string {
  const str = (v: unknown) => decodeEntities(stripTags(String(v ?? ""))).trim();
  const lines = [`Name: ${str(r.name)}`];
  for (const key of ["recipeYield", "prepTime", "cookTime", "totalTime"]) {
    if (r[key]) lines.push(`${key}: ${([] as unknown[]).concat(r[key]).map(str).join(", ")}`);
  }
  lines.push("Ingredients:", ...([] as unknown[]).concat(r.recipeIngredient ?? []).map((i) => `- ${str(i)}`));
  lines.push("Instructions:");
  const instructions = r.recipeInstructions;
  if (typeof instructions === "string") lines.push(str(instructions));
  else for (const step of walk(instructions)) if (step["@type"] === "HowToStep" && step.text) lines.push(`- ${str(step.text)}`);
  return lines.join("\n");
}

function stripTags(html: string): string {
  return html.replace(/<[^>]+>/g, "");
}

function decodeEntities(text: string): string {
  const named: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", rsquo: "’", lsquo: "‘", ldquo: "“", rdquo: "”", ndash: "–", mdash: "—", hellip: "…", frac12: "½", frac14: "¼", frac34: "¾", deg: "°" };
  return text
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&([a-z]+\d*);/gi, (m, n) => named[n.toLowerCase()] ?? m);
}
