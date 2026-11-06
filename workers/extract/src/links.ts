/** What someone shared, reduced to something we can read once and cache. */
export type SharedLink =
  | { kind: "instagram"; key: string; shortcode: string; url: string }
  | { kind: "web"; key: string; url: string };

const URL_IN_TEXT = /https?:\/\/[^\s<>"']+/i;
const INSTAGRAM_POST = /^(?:www\.|m\.)?instagram\.com$/i;
const INSTAGRAM_PATH = /^\/(?:[\w.]+\/)?(reel|reels|p|tv)\/([\w-]{5,})\/?/;

/**
 * Finds the link in whatever the share sheet sent (often just the URL, sometimes
 * "Check out this reel… https://…") and normalises it. Instagram adds tracking
 * (?igsh=…) and varies the path, so posts are keyed by their shortcode.
 */
export async function parseSharedText(text: string): Promise<SharedLink | null> {
  const raw = text.match(URL_IN_TEXT)?.[0]?.replace(/[).,!?]+$/, "");
  if (!raw) return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;

  if (INSTAGRAM_POST.test(url.hostname)) {
    const m = url.pathname.match(INSTAGRAM_PATH);
    if (!m) return null; // a profile or the home feed, not a post
    const path = m[1] === "p" ? "p" : "reel";
    const shortcode = m[2];
    return { kind: "instagram", key: `ig:${shortcode}`, shortcode, url: `https://www.instagram.com/${path}/${shortcode}/` };
  }

  url.hash = "";
  for (const p of [...url.searchParams.keys()]) if (/^(utm_|fbclid|gclid|igsh|mc_)/i.test(p)) url.searchParams.delete(p);
  const clean = url.toString();
  return { kind: "web", key: `web:${await sha256(clean)}`, url: clean };
}

export async function sha256(input: string | ArrayBuffer | Uint8Array): Promise<string> {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
