"""The Sous database, as SQLite. Same tables the server would have.

- users / ig_identities: who is who (ig_identities only for people who DM @sous)
- shares: every save received, by share button or DM (who, which post, when, how)
- posts: one row per Instagram post, fetched once however many people save it
- recipes: one extracted recipe per post
- library: each person's own entries pointing at shared recipes

The simulation replays stage 1 (users, shares, library) from scratch on every run;
posts and recipes are kept, so nothing is downloaded or extracted twice.
"""

from __future__ import annotations

import json
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

STAGE1 = """
DROP TABLE IF EXISTS users; DROP TABLE IF EXISTS ig_identities;
DROP TABLE IF EXISTS shares; DROP TABLE IF EXISTS library;
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT UNIQUE);
CREATE TABLE ig_identities (igsid TEXT PRIMARY KEY, user_id INTEGER REFERENCES users(id));
CREATE TABLE shares (
  id TEXT PRIMARY KEY,        -- client_share_id (share button) or message id (DM)
  channel TEXT,               -- share_button | dm
  user_id INTEGER, igsid TEXT, shortcode TEXT, url TEXT, kind TEXT,
  sent_at TEXT, status TEXT   -- new | duplicate | unlinked | unreadable
);
CREATE TABLE library (
  user_id INTEGER, shortcode TEXT, added_at TEXT, via_share TEXT,
  PRIMARY KEY (user_id, shortcode)
);
"""

CACHE = """
CREATE TABLE IF NOT EXISTS posts (
  shortcode TEXT PRIMARY KEY, url TEXT, kind TEXT, creator TEXT, caption TEXT,
  blog_url TEXT, blog_recipe TEXT, transcript TEXT, speech_seconds REAL,
  duration REAL, frames TEXT, fetch_error TEXT, fetched_at TEXT
);
CREATE TABLE IF NOT EXISTS recipes (
  shortcode TEXT PRIMARY KEY REFERENCES posts(shortcode),
  data TEXT, extracted_by TEXT, extracted_at TEXT
);
"""

POST_URL = re.compile(r"instagram\.com/(?:[\w.]+/)?(reel|reels|p|tv)/([\w-]+)")


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, check_same_thread=False)
    db.row_factory = sqlite3.Row
    db.executescript(STAGE1 + CACHE)
    return db


def add_users(db: sqlite3.Connection, users: list[dict]) -> None:
    for u in users:
        cur = db.execute("INSERT INTO users(name) VALUES (?)", (u["name"],))
        if u["igsid"]:  # linked once in the app with a one-time code DM'd to @sous
            db.execute("INSERT INTO ig_identities VALUES (?,?)", (u["igsid"], cur.lastrowid))
    db.commit()


def normalise(url: str) -> tuple[str, str, str] | None:
    """Any Instagram post link (with ?igsh= tracking, /reels/, a username prefix…) → (shortcode, clean url, kind)."""
    m = POST_URL.search(url or "")
    if not m:
        return None
    path, sc = ("reel" if m.group(1) in ("reel", "reels", "tv") else "p"), m.group(2)
    return sc, f"https://www.instagram.com/{path}/{sc}/", ("ig_reel" if path == "reel" else "ig_post")


def save(db: sqlite3.Connection, share_id: str, channel: str, user_id: int | None, igsid: str | None,
         url: str, sent_at: str) -> str:
    """Record one save, from either path. Returns the reply/confirmation the user sees."""
    if db.execute("SELECT 1 FROM shares WHERE id=?", (share_id,)).fetchone():
        return "(already handled)"  # retried request or re-delivered webhook
    norm = normalise(url)
    if not norm:
        db.execute("INSERT INTO shares VALUES (?,?,?,?,?,?,?,?,?)",
                   (share_id, channel, user_id, igsid, None, url, None, sent_at, "unreadable"))
        return "Sorry, that doesn't look like an Instagram post."
    sc, clean, kind = norm
    dup = user_id and db.execute("SELECT 1 FROM library WHERE user_id=? AND shortcode=?", (user_id, sc)).fetchone()
    status = "duplicate" if dup else ("new" if user_id else "unlinked")
    db.execute("INSERT INTO shares VALUES (?,?,?,?,?,?,?,?,?)",
               (share_id, channel, user_id, igsid, sc, clean, kind, sent_at, status))
    db.execute("INSERT OR IGNORE INTO posts(shortcode, url, kind) VALUES (?,?,?)", (sc, clean, kind))
    if status == "new":
        db.execute("INSERT INTO library VALUES (?,?,?,?)", (user_id, sc, sent_at, share_id))
    db.commit()
    return {"new": "Saved to Sous 👨‍🍳", "duplicate": "Already in your recipes 👍",
            "unlinked": "Got it! Link your Sous account to see it."}[status]


def ingest(db: sqlite3.Connection, event: dict) -> list[str]:
    """Handle one incoming request: a share-button POST or a Meta DM webhook."""
    if event["channel"] == "share_button":
        user = db.execute("SELECT id FROM users WHERE name=?", (event["auth_user"],)).fetchone()
        b = event["body"]
        return [save(db, b["client_share_id"], "share_button", user["id"], None, b["url"], b["shared_at"])]

    replies = []
    for entry in event["body"].get("entry", []):
        for m in entry.get("messaging", []):
            sender, msg = m["sender"]["id"], m.get("message", {})
            ident = db.execute("SELECT user_id FROM ig_identities WHERE igsid=?", (sender,)).fetchone()
            sent_at = datetime.fromtimestamp(m["timestamp"] / 1000, tz=timezone.utc).isoformat(timespec="minutes")
            for att in msg.get("attachments", []):
                if att.get("type") not in ("ig_reel", "ig_post", "share"):
                    continue
                url = (att.get("payload") or {}).get("url")
                if not url:  # Meta can send shares with no payload
                    replies.append("Sorry, I couldn't open that one. Try sharing it again?")
                    continue
                replies.append(save(db, msg["mid"], "dm", ident and ident["user_id"], sender, url, sent_at))
    return replies


def recipe(db: sqlite3.Connection, shortcode: str) -> dict | None:
    row = db.execute("SELECT data FROM recipes WHERE shortcode=?", (shortcode,)).fetchone()
    return json.loads(row["data"]) if row else None
