# Brain

The Sous brain: a Cloudflare Worker in front of one `UserBrain` Durable Object per user, each with its own SQLite. The design is on the Superthread card "Backend architecture".

## API

Everything lives under `/sous/api/v1` and needs a WorkOS access token as `Authorization: Bearer <token>`. The Worker verifies it against the shared AuthKit application's JWKS (RS256, issuer, expiry) and uses its `sub` as the user id, so each user only ever reaches their own Durable Object. A user id in a request body is never trusted. Missing or bad tokens get `401 {"error": "sign_in_required"}`.

| route | does |
| --- | --- |
| `GET /me` | `{id, preferences, about, learned, updated_at}`: `USER.md`'s frontmatter and body. `about` is the body without the `## Learned while cooking` section; `learned` is that section's entries as plain strings (no bullet, no session link), `[]` if there are none |
| `PATCH /me` | `{preferences?, about?}`. Preferences merge into what's there and a `null` value removes a key; `about` replaces only the free text and always keeps the learned section, so a `GET` then `PATCH` of `about` is stable (a learned section sent inside `about` is ignored). Returns the same shape as `GET /me` |
| `DELETE /me` | wipes the user's Durable Object, then deletes the WorkOS user. `204`, or `502` if WorkOS fails (retry is safe) |
| `GET /recipes` | `{recipes}`, newest first |
| `POST /recipes` | a recipe that validates against `packages/contracts`. The brain sets `id`, `slug`, `created_at` and `updated_at`, ignoring any sent. `201` with the saved recipe, or `400 {"error": "invalid_recipe", issues}` |
| `GET /recipes/:id` | one recipe, or `404` |
| `DELETE /recipes/:id` | deletes the recipe and everything that only exists because of it (see "Deleting a recipe"). `204`, or `404` |
| `POST /sessions` | `{recipe_id}`. Starts a live cooking session: `201 {id, recipe_id, stage, started_at, opening_line}`, or `404` for an unknown recipe |
| `POST /sessions/:id/turns` | a `TurnRequest` from `packages/contracts`: `text`, `tool_results` and phone `events`. Streams Sous's reply as server-sent events (`text`, `tool_call`, then `done` or `error`); `done` carries `awaiting_ack: {short}` when the reply ends with an instruction waiting for "Heard". `409 tool_results_required` lists the tool call ids still owed, `409 session_ended`, `409 turn_in_progress` |
| `POST /sessions/:id/end` | `{rating?, notes?}` (rating 1 to 5, notes up to 4,000 characters; the body can be empty). Closes the session and queues its reflection: `202 {id, ended_at, rating?, notes?, reflection_status: "pending"}`. `409 session_ended`, `409 turn_in_progress`, `404` |
| `GET /history` | `{cooks}`: every finished cook, newest first (up to 200), each `{session_id, recipe_id, recipe_title, started_at, ended_at, date, rating, summary, reflection_status}`. A plain SQL read, no model call. `date` is the London day, `rating` is the cook's own or the reflection's read of it (null if neither), `recipe_title` is null for a cook whose recipe row is missing |
| `GET /suggest` | "what should I cook?": `{suggestions}`, up to five `{number, recipe_id, title, reason}`, best first, only from the user's saved recipes. `number` runs from one with no gaps, for the numbered picker the chef chooses from by voice ("Hey Sous, number three"), and reasons are speech-ready. `503 suggestions_unavailable` without the Anthropic key, `502 suggestions_failed` if Claude is down or its answer is unusable (safe to retry) |
| `GET /sessions/:id` | `{session, reflection, reflection_status, reflected_at}`. `session` is a contract `Session` (the transcript, facts, rating and notes); `reflection` is null until it's done. `reflection_status` is `not_ended`, `pending`, `done` or `failed` |

## Live cooking sessions

Sous follows the kitchen voice protocol in the root `AGENTS.md` ("Decided"): it calls the cook "Chef", gives one instruction per sentence, offers rather than tells, and never speaks first. The contracts README's "Kitchen protocol" section says how the app uses `awaiting_ack` and `events`.

`POST /sessions` assembles the context once and stores it on the session: the stage prompt (`src/prompt.ts`), `USER.md`, `MEMORY.md`, the recipe, its note at `recipes/<slug>.md`, the three newest `session` notes linked to or from that note, and the notes the recipe note links to. The opening line is written by code, so no model call happens until the first turn. The model is fixed per session too, so a mid-session config change can't break the prompt cache.

Each turn sends Claude the tools, then the stage prompt and context (cached with a breakpoint), then the conversation (cached with top-level automatic caching). Thinking is off (`between_tools` on Sonnet, `disabled` on Haiku) at `low` effort, for the quickest spoken reply. Client tools are checked against the contract and streamed to the phone as `tool_call` events; a bad call never reaches the phone and goes back to Claude as an error result. `note(fact)` runs in the Durable Object: the fact is saved to the session and Claude carries on in the same stream. If a reply also has client tools, the brain holds the `note` result and sends it with the phone's results on the next turn.

`await_ack(short)` also runs in the Durable Object. It ends the turn without another Claude call: the brain holds its result for the next turn and the final `done` reports `awaiting_ack`, worked out from the stored messages (`awaitingAck` in `src/sessions.ts`) as the last `await_ack` since the chef last said anything, so it survives a round of phone tool results. It's kept out of the contract `turns`. A bare "Heard" usually gets an empty reply; an empty assistant message would break the next request, so it isn't stored and the chef's next words join the same user message. Phone `events` reach Claude as text blocks starting `[Phone]`, before anything the chef said, and aren't saved in `turns`.

A turn is saved only once the reply finishes, so after an `error` event the cook can resend the same turn. The session row keeps the raw Claude `messages` (thinking blocks included, passed back unchanged), the contract `turns` transcript, `facts` and the current `stage`. Every turn logs a `sous_turn` line with `first_text_ms`, `total_ms` and token usage including cache reads, which is how to measure time to first token.

## Post-cook reflection

`/end` saves the rating and notes, sets `ended_at` and schedules the Durable Object's alarm five seconds out, so it returns straight away. The alarm reflects on every ended session that hasn't been yet: one `claude-opus-5-5` call (`src/reflection.ts`, effort `high`, adaptive thinking, structured output against `reflectionSchema`) reads the recipe, `USER.md`, the transcript, the `note` facts and the cook's rating and notes, and returns the rating, a summary, what worked and failed, swaps, new preferences, and the ingredients, techniques and cuisine. The cook's own rating always wins over the model's. Code checks the output against the schema, tidies it (trimmed, deduplicated, lowercase names) and writes the vault in one transaction (`src/vault.ts`):

- `sessions/<date>-<recipe slug>-<id prefix>.md`: the whole reflection, linking the recipe, ingredients, techniques and cuisine. Dates are London days.
- `recipes/<slug>.md`: a line per cook under `## Cooks`, plus `## Next time`, `## Swaps`, `## Ingredients`, `## Techniques` and `## Cuisine`, and `times_cooked` and `last_cooked` in its frontmatter. Anything else in the note is kept.
- `ingredients/`, `techniques/` and `cuisines/<slug>.md`: a line per cook under `## Cooked in`.
- `USER.md`: new preferences under `## Learned while cooking`, skipping ones already there.

Every per-cook line carries the session's `[[wikilink]]`, and a rerun replaces that session's lines rather than adding more, so reflecting twice changes nothing. After writing, `links` is rebuilt from every note's `[[wikilinks]]` (`src/wikilinks.ts`), with the link's `kind` taken from the folder it points into. The next `POST /sessions` for that recipe picks all of it up through context assembly.

If Claude is down or rate limited the alarm throws and Cloudflare retries it with backoff; a later `/end` also picks up anything still pending. A refusal or output that doesn't fit the schema won't improve on retry, so it's saved as `reflection_error` and the session shows `failed`. Each reflection logs a `sous_reflection` line with its timing and token usage.

## Deleting a recipe

`DELETE /recipes/:id` runs in one transaction (`deleteRecipeCascade` in `src/vault.ts`) and removes:

- the recipe row and its `recipes/<slug>.md` note
- every session of that recipe, ended or not, and each one's `sessions/...md` note
- the per-cook lines those sessions added under `## Cooked in` in ingredient, technique and cuisine notes. A note left with no cooks is deleted; one other recipes still use stays, minus those lines
- the `links` table is then rebuilt

`USER.md` keeps everything under `## Learned while cooking`, since those are facts about the cook. Only the `([[sessions/...]])` provenance link on each line is dropped, as its note is gone. So the recipe disappears from `/history`, `/suggest` and live-cooking context. A pending reflection alarm only reads sessions that still exist, and one already running when the delete lands saves nothing.

## History and suggestions

`GET /history` (`src/history.ts`) reads the `sessions` table joined to `recipes`: ended sessions only, with the rating coming from the cook's `/end` rating, falling back to the reflection's.

`GET /suggest` builds a compact digest of the vault (`src/digest.ts`) and sends it to `claude-sonnet-5-5` (`src/suggest.ts`, effort `low`, structured output against `suggestSchema`):

- **Recipes:** each saved recipe with times cooked, last cooked (London day), average and latest rating (from finished sessions) and its first dozen ingredients. Loved recipes (latest rating 4 or 5, best average first) come first, then never cooked, then the rest, capped at 120.
- **Rated badly:** a recipe whose latest rating is 1 or 2 is left out of the candidates and listed by title so the model knows. Rate it well on a later cook and it's back. Whatever the model returns is checked against the candidates, so a badly rated, deleted or invented recipe can never come back, and the reasons are tidied.
- **Ingredients and techniques:** counted from `links`, taking each session note that links to an ingredient or technique note and the rating in that session note. Favourite ingredients have more loved cooks than poor ones, avoided ingredients at least as many poor (rated 1 or 2) as loved, and techniques to practise average under 4.
- **USER.md:** preferences and the body, trimmed to 4,000 characters.

With nothing to choose from the answer is an empty list and Claude isn't called. Each call logs a `sous_suggest` line with timing and token usage.

## Storage

`src/schema.ts` holds the migrations, applied on first use inside each Durable Object and tracked in `schema_migrations`. Add a migration by appending to the list; never edit one that has shipped. The tables are `recipes`, `files` (the vault, with `USER.md` as the profile), `links` and `sessions`, as the architecture card defines them, plus `model`, `context`, `turns` and `facts` on `sessions` for live cooking, and `rating`, `notes` and `reflection_error` for reflection. A fresh brain gets a starter `USER.md` and one obviously fake demo recipe (`src/seed.ts`).

## Config

- `WORKOS_CLIENT_ID` (var in `wrangler.jsonc`): the shared AuthKit application's production client id. Public.
- `WORKOS_API_KEY` (secret, declared in `wrangler.jsonc`, never committed): only `DELETE /me` uses it, and it returns `503` without it. For local dev put it in `.dev.vars` (see `.dev.vars.example`).
- `ANTHROPIC_API_KEY` (secret, declared the same way): starting sessions and taking turns return `503 live_sessions_unavailable` without it. Ending a session still works, and its reflection waits until the key is set and another session ends.
- `SOUS_LIVE_MODEL` (var in `wrangler.jsonc`): the model for live turns, `claude-sonnet-5-5`. Set it to `claude-haiku-5-5` if Sonnet's time to first token is too slow; new sessions pick it up.

`wrangler.jsonc` routes `build40for40.com/sous/api` and `build40for40.com/sous/api/*` on the `build40for40.com` zone, the same pattern as Sidekick. The rest of `/sous` is left for the landing page.

## Commands

```sh
cd workers/brain
npm ci
npm test                       # vitest in the Workers runtime, WorkOS and Claude mocked
npm run typecheck
npm run dev                    # local Worker on :8787
npm run types                  # regenerate worker-configuration.d.ts after changing wrangler.jsonc
npm run wrangler -- <args>     # wrangler as the 40for40 profile
```

Tests sign tokens with a key pair generated per run and serve its JWKS from a mocked `fetch`, so they never reach WorkOS. The same mock answers the Messages API with scripted streams (`mockClaude` in `src/testing.ts`), so tests never reach Claude either. CI runs typecheck and tests on every PR that touches `workers/brain/` or `packages/contracts/` (`.github/workflows/brain.yml`). Never deploy by hand.

## Deploy

`.github/workflows/brain-deploy.yml` deploys on every push to `main` that touches `workers/brain/` or `packages/contracts/`, and on manual dispatch. It runs typecheck and tests first, so PR CI (`brain.yml`) needs no secrets. Never deploy by hand.

Secrets are org-level GitHub secrets on `build40for40`, visible to the sous repo:

- `CLOUDFLARE_API_TOKEN`: already exists. The account id comes from `wrangler.jsonc`, so there is no account id secret.
- `ANTHROPIC_API_KEY` and `WORKOS_API_KEY`: a human adds both. Each deploy passes whichever are set to the Worker as Worker secrets (via the `secrets` input of `cloudflare/wrangler-action`), and skips any that are missing, so the deploy itself still succeeds. Nobody runs `wrangler secret put` by hand.

What a human still has to do:

1. Add the `ANTHROPIC_API_KEY` and `WORKOS_API_KEY` org secrets, visible to the sous repo, then re-run the deploy workflow.
2. Add the `sous://` callback to the shared WorkOS application's Staging and Production environments, without changing Joyo's defaults.
