# Sous extraction simulation

> **This is a simulation.** The saves are simulated, and the recipe-writing step was done by Claude Code. **In the Sous app, that step runs on the Sous server through the Claude API.** The plan is in [../docs/extraction-plan.md](../docs/extraction-plan.md).

Four people (Samira, Ben, Lawrence, Matt) each follow three Instagram chefs and save three of their posts to Sous. Samira and Lawrence use the share button (the main path); Ben and Matt DM @sous (the later path). The simulation runs those 37 saves through the same pipeline the app will use and writes out each person's recipes.

## What it does

1. **Saves arriving (simulated).** [cast.json](cast.json) becomes 37 incoming requests in `work/incoming/`:
   - share-button saves: `POST /api/shares` as the signed-in user, with Instagram's `?igsh=` tracking on the link
   - DMs: Meta Instagram messaging webhooks

   Some are deliberately tricky:
   - two people save the same post, sometimes by different paths (it should be fetched and extracted once)
   - Samira saves one post twice (it should be caught as a duplicate)
   - a meal-prep post (it should be skipped)
   - a recipe-in-comments post and a silent showpiece with no recipe
2. **Fetch.** For each unique post: the caption (yt-dlp, or Instagram's public embed page for photos), the recipe page if the caption links one, the audio transcribed locally with Whisper, and four frames if the video is silent. No Instagram login.
3. **Write the recipe.** One Claude call per post with all the sources. It picks the best one and fills a fixed recipe shape, or says honestly that there's no recipe. The instructions and schema are in [sous_sim/extract.py](sous_sim/extract.py).
4. **Output.** One folder per person in [output/](output/):
   - `index.md`: their recipe list
   - one Markdown file per recipe
   - [output/report.md](output/report.md): how the whole run went

## Claude API vs. the simulation

The Claude step is behind one setting:

| `RECIPE_MODEL` | Used by | How Claude is reached |
|---|---|---|
| `claude-api` | **The Sous app** | The server calls the Claude API with the Anthropic Python SDK (`claude-opus-5-5`, structured JSON output, refusal fallback). Needs `ANTHROPIC_API_KEY` on the server, never in the phone app. |
| `claude-code-handoff` (default) | This simulation | No API key on the build Mac, so each request is written to `work/handoff/requests/<post>.md`. Claude Code reads it and writes `work/handoff/responses/<post>.json`. |

Both use the same instructions, the same schema and the same validation. Every recipe file records which one produced it in `extracted_by`.

## Running it

Needs Python 3.11+, [uv](https://docs.astral.sh/uv/) and ffmpeg (`brew install uv ffmpeg`).

```bash
cd simulation
uv run sous-sim            # stages 1–2, writes extraction requests
# Claude Code answers the requests in work/handoff/
uv run sous-sim            # picks up the answers, writes output/
```

With a key, the real path runs in one go:

```bash
RECIPE_MODEL=claude-api ANTHROPIC_API_KEY=… uv run sous-sim
```

Downloads, the SQLite database and hand-off files live in `work/`, which isn't committed.
