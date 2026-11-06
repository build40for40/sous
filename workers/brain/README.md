# Brain

The Sous brain: a Cloudflare Worker in front of one `UserBrain` Durable Object per user, each with its own SQLite. The design is on the Superthread card "Backend architecture".

## API

Everything lives under `/sous/api/v1` and needs a WorkOS access token as `Authorization: Bearer <token>`. The Worker verifies it against the shared AuthKit application's JWKS (RS256, issuer, expiry) and uses its `sub` as the user id, so each user only ever reaches their own Durable Object. A user id in a request body is never trusted. Missing or bad tokens get `401 {"error": "sign_in_required"}`.

| route | does |
| --- | --- |
| `GET /me` | `{id, preferences, about, updated_at}`: `USER.md`'s frontmatter and body |
| `PATCH /me` | `{preferences?, about?}`. Preferences merge into what's there and a `null` value removes a key; `about` replaces the body |
| `DELETE /me` | wipes the user's Durable Object, then deletes the WorkOS user. `204`, or `502` if WorkOS fails (retry is safe) |
| `GET /recipes` | `{recipes}`, newest first |
| `POST /recipes` | a recipe that validates against `packages/contracts`. The brain sets `id`, `slug`, `created_at` and `updated_at`, ignoring any sent. `201` with the saved recipe, or `400 {"error": "invalid_recipe", issues}` |
| `GET /recipes/:id` | one recipe, or `404` |
| `DELETE /recipes/:id` | `204`, or `404` |
| `POST /sessions` | `{recipe_id}`. Starts a live cooking session: `201 {id, recipe_id, stage, started_at, opening_line}`, or `404` for an unknown recipe |
| `POST /sessions/:id/turns` | a `TurnRequest` from `packages/contracts`. Streams Sou's reply as server-sent events (`text`, `tool_call`, then `done` or `error`). `409 tool_results_required` lists the tool call ids still owed, `409 session_ended`, `409 turn_in_progress` |

## Live cooking sessions

`POST /sessions` assembles the context once and stores it on the session: the stage prompt (`src/prompt.ts`), `USER.md`, `MEMORY.md`, the recipe, its note at `recipes/<slug>.md`, the three newest `session` notes linked to or from that note, and the notes the recipe note links to. The opening line is written by code, so no model call happens until the first turn. The model is fixed per session too, so a mid-session config change can't break the prompt cache.

Each turn sends Claude the tools, then the stage prompt and context (cached with a breakpoint), then the conversation (cached with top-level automatic caching). Thinking is off (`between_tools` on Sonnet, `disabled` on Haiku) at `low` effort, for the quickest spoken reply. Client tools are checked against the contract and streamed to the phone as `tool_call` events; a bad call never reaches the phone and goes back to Claude as an error result. `note(fact)` runs in the Durable Object: the fact is saved to the session and Claude carries on in the same stream. If a reply also has client tools, the brain holds the `note` result and sends it with the phone's results on the next turn.

A turn is saved only once the reply finishes, so after an `error` event the cook can resend the same turn. The session row keeps the raw Claude `messages` (thinking blocks included, passed back unchanged), the contract `turns` transcript, `facts` and the current `stage`. Every turn logs a `sous_turn` line with `first_text_ms`, `total_ms` and token usage including cache reads, which is how to measure time to first token.

## Storage

`src/schema.ts` holds the migrations, applied on first use inside each Durable Object and tracked in `schema_migrations`. Add a migration by appending to the list; never edit one that has shipped. The tables are `recipes`, `files` (the vault, with `USER.md` as the profile), `links` and `sessions`, as the architecture card defines them, plus `model`, `context`, `turns` and `facts` on `sessions` for live cooking. A fresh brain gets a starter `USER.md` and one obviously fake demo recipe (`src/seed.ts`).

## Config

- `WORKOS_CLIENT_ID` (var in `wrangler.jsonc`): the shared AuthKit application's production client id. Public.
- `WORKOS_API_KEY` (secret, declared in `wrangler.jsonc`, never committed): only `DELETE /me` uses it, and it returns `503` without it. For local dev put it in `.dev.vars` (see `.dev.vars.example`).
- `ANTHROPIC_API_KEY` (secret, declared the same way): the sessions routes return `503 live_sessions_unavailable` without it.
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
