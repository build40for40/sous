# Extract

Turns what someone shares into Sous (an Instagram post, a recipe web page, or a screenshot) into a recipe in their brain. A Cloudflare Worker with two kinds of Durable Object:

- `ShareInbox`, one per user: everything they've shared and what happened to each
- `PostExtraction`, one per post: reads it and calls Claude once, however many people share it

The plan and the reasoning are in [docs/extraction-plan.md](../../docs/extraction-plan.md).

## What the MVP can and can't do

Sous reads **the caption** (one request to the post's public embed page) and **the creator's recipe page** if the caption links one. It never downloads the video or audio and never reads comments. Every request says it's Sous (`User-Agent: Sous/1.0`).

Tested against 33 real posts from 12 chefs (see `simulation/output/report.md`):

| | What | Test posts |
|---|---|---|
| ✅ **Automatic** | The full recipe is written in the caption | 13 |
| ✅ **Automatic** | The caption links the creator's recipe page | 5 |
| ✅ **Automatic** | A recipe website shared directly (any page with schema.org recipe data) | — |
| 🟡 **One extra step** | Recipe in the comments: the person screenshots the comment and shares it | 1 |
| 🟡 **One extra step** | "Comment KEYWORD and I'll DM you": the person screenshots the DM once it arrives | 1 |
| 🟡 **One extra step** | "Recipe at the link in bio": the person shares the recipe page itself | 2 |
| 🟡 **One extra step** | Private or deleted posts, recipe-card carousels: share a screenshot | — |
| ❌ **Can't** | The recipe is only spoken in the video | 5 |
| ❌ **Can't** | The recipe is only shown in the video, with nothing written | 1 |
| ⚪ **Correctly not a recipe** | Showpieces, a dish photo with only a description | 4 |
| ⚪ **Skipped on purpose** | Weekly meal-prep plans and multi-recipe posts | 1 |

So 18 of 24 real recipes (75%) are automatic, and up to 22 of 24 with a screenshot or a shared page. TikTok and YouTube links are not supported yet (`422 unsupported_link`).

A partial recipe (say, the caption lists ingredients without quantities) is still saved, with `completeness: "partial"` and what's missing listed on the share.

## API

Everything lives under `/sous/api/v1/shares` and needs the same WorkOS access token as the brain, as `Authorization: Bearer <token>`. These routes are more specific than the brain's `/sous/api/*`, so Cloudflare sends them here.

| route | does |
| --- | --- |
| `POST /shares` | `{url}`: whatever the share sheet gave (the text can include words around the link). Instagram tracking (`?igsh=`) is stripped. `202` with the share, `200` with `duplicate: true` if this person already shared that post, `422 unsupported_link`, `429 daily_limit` (`SOUS_DAILY_SHARE_LIMIT` a day), `503 extraction_unavailable` without the Anthropic key |
| `POST /shares` | `{image: {media_type, data}}`: a screenshot on its own (JPEG, PNG, WebP or GIF, base64, up to 1.9 MB) |
| `POST /shares/:id/screenshot` | `{image}`: a screenshot for a share that came back `needs_screenshot`. The share starts reading again; the saved recipe keeps the original post's link. `409 share_in_progress` while it's still reading |
| `GET /shares` | `{shares}`, newest first (up to 500) |
| `GET /shares/:id` | one share, or `404` |
| `DELETE /shares/:id` | forgets the share. A recipe it saved stays in the brain (`DELETE /recipes/:id` there) |

A share:

```json
{
  "id": "…", "kind": "link", "url": "https://www.instagram.com/reel/DTwZpo5DNVr/",
  "status": "saved", "reason": "The full recipe is in the caption.",
  "title": "Banana Coconut Cookies", "creator": "feelgoodfoodie", "recipe_id": "…",
  "source_used": "caption", "completeness": "complete", "missing": [],
  "created_at": "…", "updated_at": "…"
}
```

| status | meaning | what the app shows |
| --- | --- | --- |
| `reading` | being read (usually under a minute) | a spinner |
| `saved` | the recipe is in the brain; `recipe_id` points at it | the recipe |
| `needs_screenshot` | the recipe is somewhere Sous can't read; `reason` says where | "Share a screenshot of the recipe" |
| `no_recipe` | the post has no recipe | the reason, and a link to the post |
| `skipped` | a meal-prep plan or several recipes in one | the reason |

The app polls `GET /shares/:id` (or the list) while a share is `reading`.

## How a share is read

1. `POST /shares` records the share in the user's `ShareInbox` and asks the post's `PostExtraction`. If someone already shared that post, the result comes straight back: no fetch, no Claude call.
2. Otherwise the post's alarm runs:
   - Instagram: the embed page gives the creator and the full caption (`src/sources.ts`). A link in the caption that isn't Instagram, Linktree, Amazon and the like is read as a recipe page, for its schema.org Recipe data.
   - A web page: its schema.org Recipe data. No recipe data means `needs_screenshot`, without calling Claude.
   - A screenshot: the image itself.
3. One `claude-opus-5-5` call (`src/extract.ts`: effort `medium`, structured output, refusal fallback `"default"`). Claude picks the best source, writes the contract recipe without inventing anything, or says honestly why there isn't one. Code drops empty fields and checks the result against `packages/contracts`. A "recipe" with no ingredients or no steps becomes `needs_screenshot` instead.
4. Every waiting user's `ShareInbox` gets the result; recipes are saved with the brain's `UserBrain.createRecipe` over a cross-script Durable Object binding (`USER_BRAIN`, `script_name: sous-brain`), so they appear in `GET /recipes` like any other.

Retries: Instagram or a site answering 429/5xx, and Claude 408/409/429/5xx, are retried on the alarm after 10 s, 1 min, 5 min and 30 min. After five attempts the share becomes `needs_screenshot`. A post that's private or deleted, or a refusal, isn't retried. Each extraction logs a `sous_extract` line with its timing, status and token usage; failures log `sous_extract_error`.

## Reading from Cloudflare (tested 6 Nov)

A throwaway probe ran this Worker's own readers (`src/sources.ts`) on Cloudflare with `wrangler dev --remote`, from the London data centre (LHR). Nothing was deployed. All 10 reads succeeded:

- **8 real posts:** every one returned the creator and the full caption, matching the build Mac's run to within line-break differences, in 350–780 ms each. The posts covered recipe-in-caption reels, a photo post, a "comment RECIPE" post and a showpiece.
- **2 creator recipe pages** (Feel Good Foodie, Half Baked Harvest): both returned their schema.org recipe data.

What that doesn't prove: behaviour at volume (Instagram may rate limit a busy Worker), and from other data centres. The retries and the screenshot fallback cover a block; watch the `sous_extract_error` logs after launch.

## Not verified yet
- **Instagram's terms.** Reading the embed page from a server is still automated access. The team accepted that risk for the MVP (see the plan doc).
- **Creator credit.** The contract recipe has no field for the creator, so `creator` is on the share for now. Adding it to `packages/contracts` needs a PR agreed with the brain and app workstreams.

## Config

- `WORKOS_CLIENT_ID` (var): the shared AuthKit application, same as the brain.
- `SOUS_EXTRACT_MODEL` (var): `claude-opus-5-5`.
- `SOUS_DAILY_SHARE_LIMIT` (var): shares per user per 24 hours, `50`.
- `ANTHROPIC_API_KEY` (secret): the same org secret as the brain. Without it `POST /shares` returns `503`.

## Commands

```sh
cd workers/extract
npm ci
npm test                       # vitest in the Workers runtime; WorkOS, Claude, Instagram and recipe sites mocked
npm run typecheck
npm run dev                    # local Worker on :8787
npm run types                  # regenerate worker-configuration.d.ts after changing wrangler.jsonc
```

The tests run a stand-in `sous-brain` Worker (in `vitest.config.ts`), so they can check recipes land in the right user's brain without the real one.

## Deploy

`.github/workflows/extract-deploy.yml` deploys on every push to `main` that touches `workers/extract/` or `packages/contracts/`, after typecheck and tests, the same way as the brain. It needs the `CLOUDFLARE_API_TOKEN` and `ANTHROPIC_API_KEY` org secrets, which the brain already uses. The brain (`sous-brain`) must be deployed first, since this Worker binds its Durable Object. Never deploy by hand.
