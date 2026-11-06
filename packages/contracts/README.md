# Contracts

The shapes extraction, the brain and the app agree on. The JSON files are the source of truth: plain JSON, so Dart reads them as they are and TypeScript imports them.

```
schemas/recipe.schema.json    a recipe: title, source, servings, times, ingredients, steps with done cues
schemas/session.schema.json   a cooking session, plus the /turns request body and SSE events in $defs
tools.json                    the six cooking tools, in Claude Messages API format
examples/                     one obviously fake recipe and session that validate
src/                          TypeScript entry point: the schemas, the tools and matching types
```

Change a shape here first, in its own PR, and agree it with the workstream on the other side: extraction and the brain share the recipe, the brain and the app share the session. Keep `src/*.ts` types in step with the JSON; the tests catch most drift.

## Recipe

`title`, `ingredients` and `steps` are required. Extraction posts a recipe without `id`, `slug`, `created_at` or `updated_at`; the brain sets those. Each ingredient has a `name` and optionally a numeric `quantity` (0.5 for half), a `unit` and a free-text `note` ("finely sliced", "to taste"). Steps are in cooking order; each has the `text` to read aloud, an optional `done_cue` (what done looks like) and an optional `duration_seconds`.

## Session

A session moves through the stages `decide`, `prep`, `cook`, `present` and `feedback`, in any order. Its `turns` are the transcript:

- `cook`: what the cook said (`text`, from on-device speech to text)
- `sous`: Sou's reply, with speech-ready `text`, `tool_calls`, or both
- `tool`: `tool_results` for the sous turn just before it

For Claude, `cook` and `tool` turns become user messages and `sous` turns become assistant messages. `facts` collects everything Sou saved with `note`; `rating` (1 to 5) and `notes` come from `/end`.

### POST /sessions/:id/turns

The body is a `TurnRequest`: `text`, `tool_results`, or both. When a reply ends with `stop_reason: "tool_use"`, the next request must carry a result for every client tool call in that reply, all together.

The response is a server-sent event stream. Each event's name is its `type` and its data is a `StreamEvent`:

| type | data | meaning |
| --- | --- | --- |
| `text` | `delta` | the next chunk of Sou's reply |
| `tool_call` | `tool_call` | a client tool for the app to run |
| `done` | `stop_reason`: `end_turn` or `tool_use` | the reply is finished; `tool_use` means results are owed |
| `error` | `message` | the turn failed and the stream ends |

## Tools

`tools.json` goes straight into the `tools` parameter of a Messages API request. Every tool is `strict`, so its input schema avoids keywords strict mode rejects (`minimum`, `minLength` and friends); limits are in the descriptions instead, and the session schema's `*Call` defs hold the strict versions for validating what comes back.

| tool | runs on | input | result `content` |
| --- | --- | --- | --- |
| `start_timer` | phone | `label`, `seconds` | the new timer's id |
| `cancel_timer` | phone | `timer_id` | anything, e.g. `ok` |
| `go_to_step` | phone | `index` (zero-based into `steps`) | anything |
| `set_stage` | phone | `stage` | anything |
| `show` | phone | `view`: `step`, `ingredients` or `done_cue` | anything |
| `note` | brain | `fact` | anything, e.g. `saved` |

To Claude these are all ordinary custom tools. The brain runs `note` itself and never streams it to the app; the other five reach the app as `tool_call` events. Errors go back with `is_error: true`.

## Using it

**TypeScript (Workers):** add `"@sous/contracts": "file:../../packages/contracts"` to the Worker's dependencies, then `import { tools, recipeSchema, sessionSchema, type Recipe } from "@sous/contracts"`. The entry point is TypeScript source with JSON imports, which wrangler's bundler handles. Ajv compiles schemas with `new Function`, which Workers don't allow, so validate at runtime with a precompiled or eval-free validator.

**Dart (app):** read the JSON files directly, e.g. as Flutter assets or with codegen.

## Commands

```sh
cd packages/contracts
npm ci
npm test            # validate the examples and reject broken ones
npm run typecheck
```

CI runs both on every PR that touches `packages/contracts/` (`.github/workflows/contracts.yml`).
