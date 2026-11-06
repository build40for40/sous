# How Sous gets recipes out of Instagram

Decided on Friday 6 November 2026 (Day 5). This is the plan for the extraction side of Sous: how a recipe someone sees on Instagram ends up as a written recipe in their Sous library. The evidence behind it is in [extraction-test-set.md](extraction-test-set.md) and [LOG.md](../LOG.md).

## The three stages

1. **Saved items → a list of posts.** Who saved what.
2. **Posts → recipes.** Turn each post into a written recipe.
3. **Recipes → the library ("the brain").** Each person's recipes, ready to browse and cook from.

## Stage 1: getting posts in

**Main path: the share button.** In Instagram, tap Share → Sous.

- A small Sous panel (an iOS share extension / Android share target) appears over Instagram: "Saved to Sous ✅". The person never leaves Instagram.
- It sends the post link to the Sous API as the signed-in user: `POST /api/shares {url, client_share_id, shared_at}`.
- We know who it is from their Sous login, so there's no account linking. No Meta app or approval is needed.
- The same button works for TikTok, YouTube and recipe websites later.
- Instagram adds tracking to shared links (`?igsh=…`), so the server reduces every link to the post's ID.

**Second path, later: DM a post to @sous** on Instagram, for people who don't want to install anything.

- When someone DMs a business account, Meta sends our server a webhook with the sender and the shared post (`ig_reel` / `ig_post` with a URL).
- @sous replies in the chat ("Got it 👨‍🍳").
- It needs an @sous business account, a Meta app with messaging approval, and a one-time link between the person's Instagram account and Sous (see below).

Both paths feed the same save step, so everything after stage 1 is identical.

**Ruled out:**

- **Instagram's API for saved posts:** there isn't one. The personal-account API (Basic Display) was shut down in December 2024. The current API only covers business accounts' *own* posts.
- **"Download your information" export:** it works, but realistically nobody will do it.
- **Asking for Instagram passwords, or a hidden login inside Sous:** against Instagram's terms and risks people's accounts.

**The existing backlog of saves:** people drip-feed the ones they actually want to cook by DM'ing them. We don't bulk-import thousands of saves.

## Telling users apart

- **Share button:** the request comes from the Sous app with the person's session, so we already know who they are.
- **DM path only:** every DM webhook carries the sender's **Instagram-scoped ID (IGSID)**. It stays the same even if they change their username.
- A Sous user links their IGSID once, either by DM'ing a one-time code shown in the app (`SOUS-4821`) or by tapping a link in @sous's first reply.
- Shares that arrive before linking are kept under the IGSID and move into the account when it's linked.

## Stage 2: posts → recipes

Fetch everything the post offers (none of it needs a login):

| Source | How |
|---|---|
| Caption (video) | yt-dlp, kept on the latest version (old versions hit the login wall) |
| Caption (photo) | `instagram.com/p/<id>/embed/captioned/` |
| Blog page linked in the caption | Fetch it and read its schema.org `Recipe` data |
| Audio | yt-dlp + Whisper transcription |
| Video frames | ffmpeg, for silent videos with no written recipe |
| Comments | **Needs a login, so not fetched.** We flag "recipe is in the comments" instead |

Then **one Claude call per post** chooses the best source and writes the recipe in a fixed shape:

- **Sources in order of preference:** blog page, then a full recipe in the caption, then the spoken method, then what's visible in the frames.
- **Never mix sources blindly.** Some narration is a story or an opinion, not the method (see Bob's pie and Emily's oats in the test set).
- **"Don't invent anything" rule:** only ingredients and steps that are actually in the post.
- **Honest outcomes:** besides a recipe, Claude can return "no recipe in this post", "meal prep, skipped", or "recipe is somewhere we can't reach" (comments, DM-only).

**In the app, this runs on the Sous server through the Claude API** (Anthropic Python SDK, model `claude-opus-5-5`). The Day 5 simulation runs the same step through Claude Code instead, because there's no API key on the build Mac yet. The switch is one setting (`RECIPE_MODEL`); see [simulation/README.md](../simulation/README.md).

## Stage 3: the library

- **Posts and recipes are shared.** Each post is fetched and extracted **once**, however many people send it.
- **Each person has their own library entries:** when they added it, notes, "cooked it", collections.
- **Over time:**
  - A repeat share means no duplicate.
  - An unsent DM removes the share.
  - If the creator deletes the post, we keep our written copy.
  - When the extractor improves, we re-run it on stored posts.
- **Output:** the app reads the library from the server and keeps an offline copy. Each recipe can also be written out as a Markdown file, one per recipe, in a folder per person.

## How it fits together

```
Instagram Share → Sous share extension ─┐
                                        ├→ Sous server: save (who + which post) → queue a job
(later) DM to @sous → Meta webhook ─────┘
Worker:  fetch post (once) → Claude API → recipe → add to the person's library → push notification
Phone app ← syncs the library → offline copy, cook mode, export
```

- **Phone app:** the Flutter app in this repo. It only talks to the Sous server.
- **Server:** receives the webhooks and holds the database, the Meta token and the Claude API key. Keys never go in the app.
- **Worker:** runs yt-dlp, ffmpeg and Whisper, so it needs an ordinary server process rather than a serverless function.

## What the simulation showed (6 Nov)

Four people saved 37 posts (19 by share button, 18 by DM) from 12 chefs. Results are in [simulation/output/report.md](../simulation/output/report.md).

- **Stage 1:** 33 unique posts. The duplicate save was caught, and posts saved by two people (including across both paths) were fetched and extracted once.
- **Fetching:** all 33 posts fetched with no Instagram login. 5 recipe pages were read from creators' sites.
- **Lesson learned:** sending a full browser user agent got 403s from recipe sites and an empty Instagram embed page; a bare `Mozilla/5.0` worked.
- **Outcomes:** 24 recipes (19 complete, 4 partial, 1 estimated from frames), 4 not reachable, 4 with no recipe, 1 meal prep skipped.
  - Not reachable: in the comments, DM-only, or "link in bio" without the link.
  - No recipe: Amaury's showpieces and a description-only photo.
- **Where recipes came from:** caption 13, recipe page 5, audio 5, frames 1.
- **New format seen:** "full recipe at the link in bio" (Tasty). We can't follow a bio link from the post itself.

## Next steps: from simulation to the real app

1. **Choose where the server runs.** The worker runs yt-dlp, ffmpeg and Whisper, so it needs an ordinary process, not a serverless function. Two options:
   - a small container host (Fly.io, Render, Railway, or Cloudflare Containers alongside a Worker), with Postgres and a job queue
   - a single VM to start
2. **Turn `simulation/sous_sim` into `server/`.** Keep the logic, swap the parts:
   - SQLite becomes Postgres (or D1)
   - the stage-1 generator becomes real HTTP endpoints: `POST /api/shares`, `GET /api/library`, `GET /api/recipes/:id`, `POST /webhooks/instagram` later
   - the run loop becomes a queue worker
3. **Switch extraction to the Claude API.** `RECIPE_MODEL=claude-api`, with `ANTHROPIC_API_KEY` stored as a server secret. The code path is already written ([simulation/sous_sim/extract.py](../simulation/sous_sim/extract.py)).
4. **Keep the 33 posts as a regression test.** Save their fetched sources as fixtures (no live Instagram in CI). Check that new extractor versions keep the same statuses and don't invent ingredients.
5. **Decide on transcription:** Whisper on the server's CPU (free, slower) or a hosted Whisper API (faster, small per-minute cost).
6. **Flutter app:**
   - sign-in
   - the share extension (iOS Share Extension target and Android share intent; e.g. the `receive_sharing_intent` package)
   - library, recipe and cook-mode screens
   - offline cache
   - push notifications (APNs / FCM) for "your recipe is ready"
7. **CI and deploy:** add server tests to `ci.yml` and a deploy job, and set the API base URL per environment. Serve at build40for40.com/sous/.
8. **Store review prep:**
   - privacy policy (we store the links people save and the recipes we write)
   - App Store privacy labels
   - credit and a link to the creator on every recipe; we never re-host their video
9. **Later:** the DM to @sous path, TikTok and YouTube links, recipe websites.

## App decisions to make

Now that people have a library in the app, these need a decision:

| Decision | Options | Suggestion |
|---|---|---|
| Sign-in | Apple / Google / email link; or start anonymous on the device and upgrade later | Sign in with Apple + Google (Apple requires Sign in with Apple if we offer other social logins) |
| Posts with no recipe or meal prep | Hide them; show them greyed with the reason; let people delete | Show with the reason and an "open on Instagram" link, so nothing silently disappears |
| Recipe in the comments / link in bio | Mark "not reachable"; let people paste the text into Sous | Add "Paste the recipe": they copy the comment in Instagram and share it to Sous |
| Wrong or partial recipes | Read-only; per-person edits; "this looks wrong" button | Per-person edits on top of the shared recipe, plus a report button that feeds the regression set |
| Units and servings | As the creator wrote them; metric/US toggle; scale servings | Keep the original units, add a toggle and scaling later |
| Organising | Search, filter by chef, auto tags (dinner, dessert…), collections | Search + chef + auto tags at launch; collections later |
| Cook mode | Step by step, screen stays awake, ingredient checklist, timers | All four; timers come from the times in the steps |
| Remembering to cook (Mac's actual problem) | Nothing; weekly "you saved 3 chicken dinners" nudge; "what can I make tonight?" | A gentle weekly nudge from the app, opt-in |
| Sharing | Personal only; household libraries (Samira + Ben) | Personal at launch; households later |
| Export | None; Markdown; Paprika/Mela formats | Markdown export (already built in the simulation) |
| Non-English posts | Keep the original language; translate to English | Translate, and keep a link to the original |
| Cost limits | No cap; daily save limit per person | A generous daily cap. Each post costs one Claude call plus transcription (roughly a few cents; measure it on the regression set) |

## Open questions

- **@sous account (DM path only, not needed for launch):** someone needs to create the Instagram business or creator account and the Meta developer app, and get messaging permission approved.
- **The "brain":** is it a library on the phone, something you can ask ("what can I make with chicken tonight?"), or an export to another app?
- **Real webhook check (DM path):** confirm with a real webhook whether the `ig_reel` payload URL is the post's permalink or a video file URL.
- **Formats not seen yet:** a silent video with the recipe written on screen, and a carousel of recipe-card images.
