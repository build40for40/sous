"""Stage 3: write each person's recipe list and recipe files, plus a run report."""

from __future__ import annotations

import json
import re
import shutil
import sqlite3
from collections import Counter
from pathlib import Path

BANNER = ("> **Simulation.** Share-button saves and DMs to @sous are simulated. In the Sous app, the recipe-writing "
          "step runs on the Sous server through the Claude API; here it was done by Claude Code.\n")

STATUS_LABEL = {
    "recipe": "✅ Recipe",
    "no_recipe": "⚪ No recipe in post",
    "meal_prep": "⏭️ Meal prep, skipped",
    "recipe_not_reachable": "🔒 Recipe not reachable",
}
SOURCE_LABEL = {"blog": "recipe page", "caption": "caption", "audio": "video audio",
                "caption_and_audio": "caption + audio", "frames": "video frames", "none": "—"}


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:60]


def recipe_md(r: dict, post: sqlite3.Row, saved_by: str, added_at: str, extracted_by: str, channel: str) -> str:
    fm = {
        "title": r["title"],
        "creator": f"@{post['creator']}",
        "source": post["url"],
        "status": r["status"],
        "extracted_from": r["source_used"],
        "completeness": r["completeness"],
        "servings": r["servings"],
        "time": r["time"],
        "tags": r["tags"],
        "saved_by": saved_by,
        "saved_at": added_at,
        "saved_via": channel,
        "extracted_by": extracted_by,
    }
    out = ["---"] + [f"{k}: {json.dumps(v, ensure_ascii=False)}" for k, v in fm.items()] + ["---", ""]
    out += [f"# {r['title']}", "", f"{r['summary']}", ""]
    out += [f"From [@{post['creator']}]({post['url']}) · {SOURCE_LABEL[r['source_used']]}"
            + (f" · serves {r['servings']}" if r["servings"] else "") + (f" · {r['time']}" if r["time"] else ""), ""]
    if r["status"] != "recipe":
        out += [f"> {STATUS_LABEL[r['status']]}: {r['reason']}", ""]
    if r["ingredients"]:
        out += ["## Ingredients", ""] + [f"- [ ] {i}" for i in r["ingredients"]] + [""]
    if r["steps"]:
        out += ["## Method", ""] + [f"{n}. {s}" for n, s in enumerate(r["steps"], 1)] + [""]
    if r["tips"]:
        out += ["## Tips", ""] + [f"- {t}" for t in r["tips"]] + [""]
    if r["missing"]:
        out += ["## Not in the post", ""] + [f"- {m}" for m in r["missing"]] + [""]
    return "\n".join(out)


def render(db: sqlite3.Connection, out_dir: Path) -> None:
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)
    for user in db.execute("SELECT * FROM users ORDER BY id"):
        udir = out_dir / user["name"].lower()
        udir.mkdir()
        rows = db.execute(
            "SELECT l.added_at, s.channel, p.*, r.data, r.extracted_by FROM library l JOIN posts p USING(shortcode) "
            "JOIN shares s ON s.id = l.via_share LEFT JOIN recipes r USING(shortcode) "
            "WHERE l.user_id=? ORDER BY l.added_at", (user["id"],)).fetchall()
        via = {"share_button": "share button", "dm": "DM to @sous"}[rows[0]["channel"]] if rows else "—"
        index = [f"# {user['name']}'s recipes", "", BANNER,
                 f"{len(rows)} posts saved to Sous (via {via}).", "",
                 "| # | Recipe | Chef | From | Status |", "|---|---|---|---|---|"]
        for n, row in enumerate(rows, 1):
            if not row["data"]:
                why = "fetch failed" if row["fetch_error"] else "not extracted yet"
                index.append(f"| {n} | [{row['shortcode']}]({row['url']}) | @{row['creator'] or '?'} | — | ❌ {why} |")
                continue
            r = json.loads(row["data"])
            fname = f"{slug(row['creator'] or 'unknown')}-{slug(r['title'])}.md"
            (udir / fname).write_text(recipe_md(r, row, user["name"], row["added_at"], row["extracted_by"], row["channel"]))
            index.append(f"| {n} | [{r['title']}]({fname}) | @{row['creator']} | "
                         f"{SOURCE_LABEL[r['source_used']]} | {STATUS_LABEL[r['status']]} |")
        (udir / "index.md").write_text("\n".join(index) + "\n")
    _report(db, out_dir)


def _report(db: sqlite3.Connection, out_dir: Path) -> None:
    shares = db.execute("SELECT COUNT(*) n FROM shares").fetchone()["n"]
    dups = db.execute("SELECT COUNT(*) n FROM shares WHERE status='duplicate'").fetchone()["n"]
    posts = db.execute("SELECT COUNT(*) n FROM posts").fetchone()["n"]
    entries = db.execute("SELECT COUNT(*) n FROM library").fetchone()["n"]
    shared = db.execute("SELECT shortcode, COUNT(*) n FROM library GROUP BY shortcode HAVING n>1").fetchall()
    failed = db.execute("SELECT shortcode, url, fetch_error FROM posts WHERE fetch_error IS NOT NULL").fetchall()
    recs = [(r["shortcode"], json.loads(r["data"]), r["extracted_by"]) for r in db.execute("SELECT * FROM recipes")]
    status = Counter(r["status"] for _, r, _ in recs)
    source = Counter(r["source_used"] for _, r, _ in recs if r["status"] == "recipe")
    complete = Counter(r["completeness"] for _, r, _ in recs if r["status"] == "recipe")
    by = Counter(b for _, _, b in recs)

    by_channel = {r["channel"]: r["n"] for r in db.execute("SELECT channel, COUNT(*) n FROM shares GROUP BY channel")}
    cross = db.execute("SELECT COUNT(*) n FROM (SELECT shortcode FROM shares GROUP BY shortcode "
                       "HAVING COUNT(DISTINCT channel) > 1)").fetchone()["n"]
    lines = ["# Simulation report", "", BANNER,
             "## Stage 1: saves arriving", "",
             f"- {shares} saves from {db.execute('SELECT COUNT(*) n FROM users').fetchone()['n']} people: "
             f"{by_channel.get('share_button', 0)} by share button (main path), {by_channel.get('dm', 0)} by DM to @sous",
             f"- {dups} duplicate (same person, same post): \"Already in your recipes\"",
             f"- {cross} posts arrived by both paths and still map to one post",
             f"- {entries} library entries, pointing at **{posts} unique posts**",
             f"- {len(shared)} posts were sent by more than one person, fetched and extracted once each", "",
             "## Stage 2: posts → recipes", "",
             f"- Fetched without a login: {posts - len(failed)} of {posts}"]
    lines += [f"  - ❌ [{f['shortcode']}]({f['url']}): {f['fetch_error']}" for f in failed]
    lines += [f"- Extracted: {len(recs)} (by {', '.join(f'{k}: {v}' for k, v in by.items())})", "",
              "| Outcome | Posts |", "|---|---|"]
    lines += [f"| {STATUS_LABEL[k]} | {v} |" for k, v in status.most_common()]
    lines += ["", "Where the recipes came from:", "", "| Source | Recipes |", "|---|---|"]
    lines += [f"| {SOURCE_LABEL[k]} | {v} |" for k, v in source.most_common()]
    lines += ["", "| Completeness | Recipes |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in complete.most_common()]
    lines += ["", "## Every post", "", "| Post | Chef | Outcome | From | Reason |", "|---|---|---|---|---|"]
    for sc, r, _ in sorted(recs, key=lambda x: x[1]["status"]):
        post = db.execute("SELECT url, creator FROM posts WHERE shortcode=?", (sc,)).fetchone()
        lines.append(f"| [{r['title']}]({post['url']}) | @{post['creator']} | {STATUS_LABEL[r['status']]} | "
                     f"{SOURCE_LABEL[r['source_used']]} | {r['reason'].replace('|', '/')} |")
    (out_dir / "report.md").write_text("\n".join(lines) + "\n")
