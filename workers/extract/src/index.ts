import { BASE_PATH, error, HttpError, isPlainObject, json, readJson } from "./http";
import type { ImageType } from "./extract";
import type { ShareInbox, Share } from "./inbox";
import { parseSharedText, sha256 } from "./links";
import type { PostExtraction, PostSource } from "./post";
import { authenticate } from "./workos";

export { ShareInbox } from "./inbox";
export { PostExtraction } from "./post";

const SHARES = `${BASE_PATH}/shares`;
const MAX_LINK_BODY = 16 * 1024;
// A Durable Object SQLite value tops out at 2 MB, so screenshots are capped below that.
export const MAX_IMAGE_BYTES = 1_900_000;
const MAX_SCREENSHOT_BODY = Math.ceil((MAX_IMAGE_BYTES * 4) / 3) + 16 * 1024;
const IMAGE_TYPES = new Set<ImageType>(["image/jpeg", "image/png", "image/webp", "image/gif"]);

type Rpc<T> = { [K in keyof T]: T[K] extends (...args: infer A) => infer R ? (...args: A) => Promise<Awaited<R>> : never };
type Inbox = Rpc<Pick<ShareInbox, "addShare" | "attachScreenshot" | "list" | "get" | "remove" | "complete" | "wipe">>;
type Post = Rpc<Pick<PostExtraction, "request">>;

export default {
  async fetch(request, env): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname !== SHARES && !pathname.startsWith(`${SHARES}/`)) return error(404, "not_found");

    const userId = await authenticate(request, env.WORKOS_CLIENT_ID);
    if (!userId) return error(401, "sign_in_required", undefined, { "WWW-Authenticate": 'Bearer realm="sous"' });

    const inbox = env.SHARE_INBOX.get(env.SHARE_INBOX.idFromName(userId)) as unknown as Inbox;
    try {
      return await route(request, pathname.slice(SHARES.length), userId, inbox, env);
    } catch (e) {
      if (e instanceof HttpError) return e.toResponse();
      throw e;
    }
  },
} satisfies ExportedHandler<Env>;

async function route(request: Request, path: string, userId: string, inbox: Inbox, env: Env): Promise<Response> {
  const { method } = request;

  if (path === "" || path === "/") {
    if (method === "GET") return json({ shares: await inbox.list() });
    if (method === "DELETE") {
      // Account deletion: the app calls this before the brain's DELETE /me.
      await inbox.wipe();
      return new Response(null, { status: 204 });
    }
    if (method !== "POST") return methodNotAllowed("GET, POST, DELETE");
    if (!env.ANTHROPIC_API_KEY) return error(503, "extraction_unavailable");
    const body = await readJson(request, MAX_SCREENSHOT_BODY);
    if (!isPlainObject(body)) throw new HttpError(400, "invalid_share", { message: "Send {url} or {image: {media_type, data}}." });
    if (body.image !== undefined) return shareScreenshot(body.image, null, userId, inbox, env);
    return shareLink(body, userId, inbox, env);
  }

  const match = path.match(/^\/([0-9a-f-]{36})(\/screenshot)?$/);
  if (!match) return error(404, "not_found");
  const [, shareId, screenshot] = match;

  if (screenshot) {
    if (method !== "POST") return methodNotAllowed("POST");
    if (!env.ANTHROPIC_API_KEY) return error(503, "extraction_unavailable");
    const existing = await inbox.get(shareId);
    if (!existing) return error(404, "share_not_found");
    if (existing.status !== "needs_screenshot") return error(409, existing.status === "reading" ? "share_in_progress" : "screenshot_not_needed");
    const body = await readJson(request, MAX_SCREENSHOT_BODY);
    if (!isPlainObject(body) || body.image === undefined) throw new HttpError(400, "invalid_share", { message: "Send {image: {media_type, data}}." });
    return shareScreenshot(body.image, existing, userId, inbox, env);
  }

  if (method === "GET") {
    const share = await inbox.get(shareId);
    return share ? json(share) : error(404, "share_not_found");
  }
  if (method === "DELETE") return (await inbox.remove(shareId)) ? new Response(null, { status: 204 }) : error(404, "share_not_found");
  return methodNotAllowed("GET, DELETE");
}

/** POST /shares {url}: whatever the share sheet gave us, usually an Instagram link. */
async function shareLink(body: Record<string, unknown>, userId: string, inbox: Inbox, env: Env): Promise<Response> {
  const text = typeof body.url === "string" ? body.url : typeof body.text === "string" ? body.text : null;
  if (!text || text.length > MAX_LINK_BODY) throw new HttpError(400, "invalid_share", { message: "Send {url} with the shared link." });
  const link = await parseSharedText(text);
  if (!link) return error(422, "unsupported_link", { message: "Share an Instagram post or reel, or a recipe web page." });

  const added = await inbox.addShare(userId, "link", link.key, link.url, dailyLimit(env));
  if (added === "daily_limit") return error(429, "daily_limit", { limit: dailyLimit(env) });
  if (added.duplicate) return json({ ...added.share, duplicate: true });

  const source: PostSource = link.kind === "instagram" ? { kind: "instagram", key: link.key, url: link.url, shortcode: link.shortcode } : { kind: "web", key: link.key, url: link.url };
  return json(await start(source, added.share, userId, inbox, env), 202);
}

/** A screenshot, either as a new share or for a share that needed one. */
async function shareScreenshot(image: unknown, existing: Share | null, userId: string, inbox: Inbox, env: Env): Promise<Response> {
  if (!isPlainObject(image) || typeof image.data !== "string" || !IMAGE_TYPES.has(image.media_type as ImageType)) {
    throw new HttpError(400, "invalid_image", { message: "Send image as {media_type: image/jpeg|png|webp|gif, data: base64}." });
  }
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(image.data), (c) => c.charCodeAt(0));
  } catch {
    throw new HttpError(400, "invalid_image", { message: "data isn't base64." });
  }
  if (bytes.byteLength > MAX_IMAGE_BYTES) return error(413, "image_too_large", { max_bytes: MAX_IMAGE_BYTES });
  if (bytes.byteLength === 0) throw new HttpError(400, "invalid_image", { message: "The image is empty." });

  const key = `img:${await sha256(bytes)}`;
  let share: Share;
  if (existing) {
    const attached = await inbox.attachScreenshot(existing.id, key, dailyLimit(env));
    if (attached === "not_found") return error(404, "share_not_found");
    if (attached === "daily_limit") return error(429, "daily_limit", { limit: dailyLimit(env) });
    if (typeof attached === "string") return error(409, attached); // changed status since the check above
    share = attached;
  } else {
    const added = await inbox.addShare(userId, "screenshot", key, null, dailyLimit(env));
    if (added === "daily_limit") return error(429, "daily_limit", { limit: dailyLimit(env) });
    if (added.duplicate) return json({ ...added.share, duplicate: true });
    share = added.share;
  }
  const source: PostSource = { kind: "screenshot", key, url: share.url, media_type: image.media_type as ImageType, image: bytes.buffer as ArrayBuffer };
  return json(await start(source, share, userId, inbox, env), 202);
}

/** Hands the share to the post's Durable Object. A post someone else already shared comes back finished. */
async function start(source: PostSource, share: Share, userId: string, inbox: Inbox, env: Env): Promise<Share> {
  const post = env.POST_EXTRACTION.get(env.POST_EXTRACTION.idFromName(source.key)) as unknown as Post;
  const cached = await post.request(source, { user_id: userId, share_id: share.id });
  return cached ? ((await inbox.complete(share.id, cached)) ?? share) : share;
}

function dailyLimit(env: Env): number {
  const n = Number(env.SOUS_DAILY_SHARE_LIMIT);
  return Number.isInteger(n) && n > 0 ? n : 50;
}

function methodNotAllowed(allow: string): Response {
  return error(405, "method_not_allowed", undefined, { Allow: allow });
}
