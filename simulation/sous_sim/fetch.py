"""Stage 2a: fetch everything a post offers. Nothing here needs an Instagram login.

- Caption: yt-dlp for videos; the public embed page for photo posts (yt-dlp refuses them).
- Blog: if the caption links to a recipe site, read its schema.org Recipe data.
- Audio: yt-dlp + ffmpeg + faster-whisper (runs locally; the server would do the same).
- Frames: four stills per video, used only if the video is silent.
- Comments: not fetched. They need a login, so extraction flags "recipe in comments" instead.
"""

from __future__ import annotations

import html
import json
import re
import sqlite3
import subprocess
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import yt_dlp

# A full Safari user agent gets 403s from recipe sites and an empty Instagram embed page;
# the bare one gets through to both (tested 6 Nov 2026).
UA = "Mozilla/5.0"
SKIP_LINK_HOSTS = ("instagram.com", "linktr.ee", "beacons.ai", "tiktok.com", "youtube.com", "amzn.to", "amazon.")


def _get(url: str, timeout: int = 20) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en-GB,en;q=0.9"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def photo_caption(shortcode: str) -> tuple[str | None, str]:
    """Caption of a photo post from instagram.com/p/<id>/embed/captioned/."""
    page = _get(f"https://www.instagram.com/p/{shortcode}/embed/captioned/")
    m = re.search(r'class="Caption"[^>]*>(.*?)</div>', page, re.S)
    if not m:
        raise RuntimeError("no caption on embed page")
    raw = m.group(1)
    user = re.search(r'class="CaptionUsername"[^>]*>([^<]+)<', raw)
    text = re.sub(r"<br\s*/?>", "\n", raw)
    text = html.unescape(re.sub(r"<[^>]+>", "", text))
    if user:
        text = text.replace(user.group(1), "", 1)
    text = re.sub(r"\s*View all \d+ comments\s*$", "", text).strip()
    return (user.group(1).strip() if user else None), text


def find_blog_url(caption: str) -> str | None:
    for url in re.findall(r"https?://[^\s)\]]+", caption or ""):
        if not any(h in url for h in SKIP_LINK_HOSTS):
            return url.rstrip(".,!")
    return None


def blog_recipe(url: str) -> str | None:
    """Read schema.org Recipe JSON-LD from a recipe site; return it as compact text."""
    page = _get(url)
    for block in re.findall(r'<script[^>]*application/ld\+json[^>]*>(.*?)</script>', page, re.S):
        try:
            data = json.loads(block.strip())
        except json.JSONDecodeError:
            continue
        for node in _walk(data):
            types = node.get("@type")
            types = types if isinstance(types, list) else [types]
            if "Recipe" in types:
                return _recipe_text(node)
    return None


def _walk(data):
    if isinstance(data, dict):
        yield data
        for v in data.values():
            yield from _walk(v)
    elif isinstance(data, list):
        for v in data:
            yield from _walk(v)


def _recipe_text(r: dict) -> str:
    lines = [f"Name: {r.get('name', '')}"]
    for key in ("recipeYield", "prepTime", "cookTime", "totalTime"):
        if r.get(key):
            lines.append(f"{key}: {r[key]}")
    lines.append("Ingredients:")
    lines += [f"- {html.unescape(str(i))}" for i in r.get("recipeIngredient", [])]
    lines.append("Instructions:")
    for step in _walk(r.get("recipeInstructions", [])):
        if step.get("@type") == "HowToStep" and step.get("text"):
            lines.append(f"- {html.unescape(step['text'])}")
    if isinstance(r.get("recipeInstructions"), str):
        lines.append(html.unescape(r["recipeInstructions"]))
    return "\n".join(lines)


def download(post: sqlite3.Row, media_dir: Path) -> dict:
    """Fetch one post's caption, blog and media. Returns columns to save."""
    sc, url = post["shortcode"], post["url"]
    out = media_dir / sc
    out.mkdir(parents=True, exist_ok=True)
    row: dict = {"fetched_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    try:
        opts = {"quiet": True, "no_warnings": True, "noprogress": True, "format": "best", "outtmpl": str(out / "video.%(ext)s")}
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=True)
        row["creator"] = info.get("channel") or info.get("uploader_id") or info.get("uploader")
        row["caption"] = info.get("description") or ""
        row["duration"] = info.get("duration")
    except yt_dlp.utils.DownloadError as e:
        if "no video" not in str(e).lower():
            row["fetch_error"] = str(e)[:300]
            return row
        try:  # photo post
            row["creator"], row["caption"] = photo_caption(sc)
        except Exception as e2:  # noqa: BLE001
            row["fetch_error"] = f"photo caption: {e2}"[:300]
            return row

    blog = find_blog_url(row.get("caption", ""))
    if blog:
        row["blog_url"] = blog
        try:
            row["blog_recipe"] = blog_recipe(blog)
        except Exception as e:  # noqa: BLE001  — not fatal: caption and audio still work
            row["blog_recipe"] = f"(could not open the page: {e})"

    video = next(out.glob("video.*"), None)
    if video:
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(video), "-vn", "-ac", "1", "-ar", "16000",
                        str(out / "audio.wav")], check=True)
        dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                    str(video)], capture_output=True, text=True).stdout.strip() or 0)
        row["duration"] = row.get("duration") or dur
        frames = []
        for i, f in enumerate((0.15, 0.4, 0.65, 0.9)):
            fp = out / f"frame_{i}.jpg"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", f"{dur * f:.2f}", "-i", str(video),
                            "-frames:v", "1", "-vf", "scale=480:-1", str(fp)], check=True)
            frames.append(str(fp))
        row["frames"] = json.dumps(frames)
    return row


def transcribe_all(db: sqlite3.Connection, media_dir: Path, model_size: str = "small") -> None:
    todo = [r["shortcode"] for r in db.execute("SELECT shortcode FROM posts WHERE transcript IS NULL")
            if (media_dir / r["shortcode"] / "audio.wav").exists()]
    if not todo:
        return
    from faster_whisper import WhisperModel
    model = WhisperModel(model_size, device="cpu", compute_type="int8")
    for sc in todo:
        segs, _ = model.transcribe(str(media_dir / sc / "audio.wav"), vad_filter=True)
        segs = list(segs)
        text = " ".join(s.text.strip() for s in segs)
        speech = sum(s.end - s.start for s in segs)
        db.execute("UPDATE posts SET transcript=?, speech_seconds=? WHERE shortcode=?", (text, speech, sc))
        db.commit()
        print(f"  transcribed {sc}: {speech:.0f}s of speech")


def fetch_all(db: sqlite3.Connection, media_dir: Path, workers: int = 4) -> None:
    posts = list(db.execute("SELECT * FROM posts WHERE fetched_at IS NULL OR fetch_error IS NOT NULL"))
    print(f"Fetching {len(posts)} posts…")
    with ThreadPoolExecutor(workers) as pool:
        for post, row in zip(posts, pool.map(lambda p: download(p, media_dir), posts)):
            err = row.pop("fetch_error", None)
            cols = ", ".join(f"{k}=?" for k in row)
            db.execute(f"UPDATE posts SET {cols}, fetch_error=? WHERE shortcode=?",
                       (*row.values(), err, post["shortcode"]))
            db.commit()
            flag = f"ERROR {err}" if err else "ok"
            print(f"  {post['shortcode']} @{row.get('creator')}: {flag}")
    transcribe_all(db, media_dir)
