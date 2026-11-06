"""Stage 2b: turn a fetched post into a written recipe with Claude.

One Claude call per post. The same instructions and output shape are used whichever
way Claude is reached; only the transport changes, chosen by RECIPE_MODEL:

  RECIPE_MODEL=claude-api           THE REAL APP. The Sous server calls the Claude API
                                    (Anthropic Python SDK, model below) with its own key.
  RECIPE_MODEL=claude-code-handoff  THE DAY 5 SIMULATION (default). No API key on the build
                                    Mac, so each request is written to work/handoff/requests/
                                    and Claude Code writes the answer to work/handoff/responses/.
                                    Re-running picks the answers up.

Every recipe records `extracted_by`, so simulated output is never mistaken for real output.
"""

from __future__ import annotations

import base64
import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

API_MODEL = "claude-opus-5-5"

SYSTEM = """You turn an Instagram cooking post into a written recipe for Sous, an app people cook from instead of watching videos.

You get every source the post offers: the caption, sometimes the recipe page the caption links to, sometimes a transcript of the video's audio, sometimes stills from a silent video. Comments are never available.

Rules:
1. Use the best source, don't blend them blindly. Prefer, in order: the linked recipe page; a full recipe written in the caption; the method spoken in the audio; what is visible in the frames. Use a second source only to fill a gap the first leaves (for example quantities spoken in the audio when the caption lists only ingredient names).
2. Narration is often not the method: a story, an opinion, an ad read. Ignore it unless it actually describes ingredients or steps.
3. Never invent anything. Only include ingredients, quantities, times and steps that are in the sources. If a quantity is missing, write the ingredient without one and list what is missing in `missing`. Do not add salt, oil, water or other "obvious" ingredients that are not mentioned.
4. Write steps as short, numbered-style instructions in your own words, in British English, in the order you'd cook them. Keep the creator's quantities and units as given.
5. If the caption is in two languages, use the English part.
6. Choose `status` honestly:
   - "recipe": you could write a usable recipe.
   - "no_recipe": the post shows food but contains no recipe (a showpiece, a review, a trend video).
   - "meal_prep": a weekly meal-prep plan or several recipes bundled in one post. Sous skips these.
   - "recipe_not_reachable": the post says the recipe is somewhere you can't see (the comments, a DM after commenting a keyword) and the sources you have don't contain it. Still fill in what you can (title, any ingredients mentioned) and explain in `reason`.
7. `completeness`: "complete" if someone could cook it as written; "partial" if quantities or steps are missing; "estimated" if it is reconstructed from frames; "none" if there is no recipe.
"""

SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["status", "reason", "title", "summary", "servings", "time", "ingredients", "steps", "tips",
                 "source_used", "completeness", "missing", "tags"],
    "properties": {
        "status": {"type": "string", "enum": ["recipe", "no_recipe", "meal_prep", "recipe_not_reachable"]},
        "reason": {"type": "string", "description": "One sentence: why this status and which source was used."},
        "title": {"type": "string"},
        "summary": {"type": "string", "description": "One sentence describing the dish."},
        "servings": {"type": ["string", "null"]},
        "time": {"type": ["string", "null"], "description": "Total time if stated, else null."},
        "ingredients": {"type": "array", "items": {"type": "string"}},
        "steps": {"type": "array", "items": {"type": "string"}},
        "tips": {"type": "array", "items": {"type": "string"}},
        "source_used": {"type": "string", "enum": ["blog", "caption", "audio", "caption_and_audio", "frames", "none"]},
        "completeness": {"type": "string", "enum": ["complete", "partial", "estimated", "none"]},
        "missing": {"type": "array", "items": {"type": "string"}},
        "tags": {"type": "array", "items": {"type": "string"}, "description": "e.g. dinner, dessert, baking, vegetarian"},
    },
}


def use_frames(post: sqlite3.Row) -> bool:
    """Frames only for silent videos (less than 5 seconds of speech)."""
    return bool(post["frames"]) and (post["speech_seconds"] or 0) < 5


def user_text(post: sqlite3.Row) -> str:
    parts = [f"Post: {post['url']}", f"Creator: @{post['creator']}", f"Type: {post['kind']}"]
    if post["duration"]:
        parts.append(f"Video length: {post['duration']:.0f}s, speech detected: {post['speech_seconds'] or 0:.0f}s")
    parts.append(f"\n<caption>\n{post['caption'] or '(no caption)'}\n</caption>")
    if post["blog_url"]:
        parts.append(f"\n<recipe_page url=\"{post['blog_url']}\">\n{post['blog_recipe'] or '(could not read a recipe from this page)'}\n</recipe_page>")
    if post["transcript"] is not None and post["kind"] == "ig_reel":
        parts.append(f"\n<audio_transcript>\n{post['transcript'] or '(no speech)'}\n</audio_transcript>")
    if use_frames(post):
        parts.append("\nThe video is silent. Four stills from it follow, in order.")
    return "\n".join(parts)


def _validate(data: dict) -> dict:
    missing = [k for k in SCHEMA["required"] if k not in data]
    if missing:
        raise ValueError(f"response missing {missing}")
    if data["status"] not in SCHEMA["properties"]["status"]["enum"]:
        raise ValueError(f"bad status {data['status']}")
    return data


class ClaudeApi:
    """The real app: one Claude API call per post (server-side; key from the environment)."""

    name = f"claude-api / {API_MODEL}"

    def __init__(self):
        import anthropic
        self.anthropic = anthropic
        self.client = anthropic.Anthropic()  # ANTHROPIC_API_KEY, never in the phone app

    def extract(self, post: sqlite3.Row, request_dir: Path, response_dir: Path) -> dict | None:
        content: list[dict] = [{"type": "text", "text": user_text(post)}]
        if use_frames(post):
            for fp in json.loads(post["frames"]):
                data = base64.standard_b64encode(Path(fp).read_bytes()).decode()
                content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": data}})
        response = self.client.beta.messages.create(
            model=API_MODEL,
            max_tokens=16000,
            system=SYSTEM,
            messages=[{"role": "user", "content": content}],
            output_config={"effort": "medium", "format": {"type": "json_schema", "schema": SCHEMA}},
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",  # re-run on Anthropic's recommended model if a classifier declines
        )
        if response.stop_reason == "refusal":
            raise RuntimeError(f"Claude declined: {response.stop_details}")
        text = next(b.text for b in response.content if b.type == "text")
        return _validate(json.loads(text))


class ClaudeCodeHandoff:
    """The Day 5 simulation: requests go to files; Claude Code writes the responses."""

    name = "claude-code-handoff (simulation)"

    def extract(self, post: sqlite3.Row, request_dir: Path, response_dir: Path) -> dict | None:
        sc = post["shortcode"]
        resp = response_dir / f"{sc}.json"
        if resp.exists():
            return _validate(json.loads(resp.read_text()))
        request_dir.mkdir(parents=True, exist_ok=True)
        frames = "\n".join(f"- {fp}" for fp in json.loads(post["frames"])) if use_frames(post) else "(none)"
        (request_dir / f"{sc}.md").write_text(
            f"# Extraction request: {sc}\n\n"
            f"Write the answer as JSON matching the schema below to:\n`{resp}`\n\n"
            f"## Instructions (system prompt)\n\n{SYSTEM}\n\n"
            f"## Post\n\n{user_text(post)}\n\n"
            f"## Frame images (read these if listed)\n\n{frames}\n\n"
            f"## Output JSON schema\n\n```json\n{json.dumps(SCHEMA, indent=2)}\n```\n"
        )
        return None


def backend():
    choice = os.environ.get("RECIPE_MODEL", "claude-code-handoff")
    return {"claude-api": ClaudeApi, "claude-code-handoff": ClaudeCodeHandoff}[choice]()


def extract_all(db: sqlite3.Connection, work: Path) -> tuple[int, int]:
    be = backend()
    request_dir, response_dir = work / "handoff" / "requests", work / "handoff" / "responses"
    done = pending = 0
    for post in db.execute("SELECT * FROM posts WHERE fetch_error IS NULL AND shortcode NOT IN "
                           "(SELECT shortcode FROM recipes)").fetchall():
        data = be.extract(post, request_dir, response_dir)
        if data is None:
            pending += 1
            continue
        db.execute("INSERT OR REPLACE INTO recipes VALUES (?,?,?,?)",
                   (post["shortcode"], json.dumps(data), be.name, datetime.now(timezone.utc).isoformat(timespec="seconds")))
        db.commit()
        done += 1
    print(f"Extraction via {be.name}: {done} new recipes, {pending} waiting for a response")
    return done, pending
