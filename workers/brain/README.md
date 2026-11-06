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

## Storage

`src/schema.ts` holds the migrations, applied on first use inside each Durable Object and tracked in `schema_migrations`. Add a migration by appending to the list; never edit one that has shipped. The tables are `recipes`, `files` (the vault, with `USER.md` as the profile), `links` and `sessions`, as the architecture card defines them. A fresh brain gets a starter `USER.md` and one obviously fake demo recipe (`src/seed.ts`).

## Config

- `WORKOS_CLIENT_ID` (var in `wrangler.jsonc`): the shared AuthKit application's production client id. Public.
- `WORKOS_API_KEY` (secret, declared in `wrangler.jsonc`, never committed): only `DELETE /me` uses it, and it returns `503` without it. For local dev put it in `.dev.vars` (see `.dev.vars.example`).

`wrangler.jsonc` routes `build40for40.com/sous/api` and `build40for40.com/sous/api/*` on the `build40for40.com` zone, the same pattern as Sidekick. The rest of `/sous` is left for the landing page.

## Commands

```sh
cd workers/brain
npm ci
npm test                       # vitest in the Workers runtime, WorkOS mocked
npm run typecheck
npm run dev                    # local Worker on :8787
npm run types                  # regenerate worker-configuration.d.ts after changing wrangler.jsonc
npm run wrangler -- <args>     # wrangler as the 40for40 profile
```

Tests sign tokens with a key pair generated per run and serve its JWKS from a mocked `fetch`, so they never reach WorkOS. CI runs typecheck and tests on every PR that touches `workers/brain/` or `packages/contracts/` (`.github/workflows/brain.yml`). Never deploy by hand.

## Deploy

`.github/workflows/brain-deploy.yml` deploys on every push to `main` that touches `workers/brain/` or `packages/contracts/`, and on manual dispatch. It runs typecheck and tests first, so PR CI (`brain.yml`) needs no secrets. Never deploy by hand.

Secrets are org-level GitHub secrets on `build40for40`, visible to the sous repo:

- `CLOUDFLARE_API_TOKEN`: already exists. The account id comes from `wrangler.jsonc`, so there is no account id secret.
- `ANTHROPIC_API_KEY` and `WORKOS_API_KEY`: a human adds both. Each deploy passes whichever are set to the Worker as Worker secrets (via the `secrets` input of `cloudflare/wrangler-action`), and skips any that are missing, so the deploy itself still succeeds. Nobody runs `wrangler secret put` by hand.

What a human still has to do:

1. Add the `ANTHROPIC_API_KEY` and `WORKOS_API_KEY` org secrets, visible to the sous repo, then re-run the deploy workflow.
2. Add the `sous://` callback to the shared WorkOS application's Staging and Production environments, without changing Joyo's defaults.
