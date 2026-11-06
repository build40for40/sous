"""Stage 1 (simulated): how saved posts reach the Sous server.

Two paths, generated from cast.json (`saves_via`):

1. Share button (main path). In Instagram, Share → Sous. The Sous share extension
   sends the link to the Sous API as the signed-in user:
       POST /api/shares  {url, shared_text, client_share_id, shared_at}
       Authorization: Bearer <the user's Sous session>
   We know who it is from their Sous login. No Meta setup needed.
   Instagram's share sheet adds tracking (?igsh=…) to the link, so the server
   normalises it to the post's shortcode.

2. DM to @sous (secondary path). Meta POSTs an Instagram messaging webhook:
   `entry[].messaging[]` with `sender.id` (Instagram-scoped ID, IGSID) and an
   `ig_reel` / `ig_post` attachment. The IGSID is linked to a Sous user once,
   with a code. To check with a real webhook: whether `payload.url` is the
   post's permalink (assumed here) or a video URL.
"""

from __future__ import annotations

import hashlib
import json
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

SOUS_IG_ID = "17841400000000000"  # the @sous business account (fake)
START = datetime(2026, 11, 2, 18, 0, tzinfo=timezone.utc)


def igsid(name: str) -> str:
    """A stable fake Instagram-scoped ID per person."""
    return str(int(hashlib.sha256(name.encode()).hexdigest()[:15], 16))


def _share_button(user: str, post_path: str, when: datetime, n: int) -> dict:
    tracking = hashlib.sha256(f"{user}{post_path}".encode()).hexdigest()[:16]
    url = f"https://www.instagram.com/{post_path}/?igsh={tracking}"
    return {
        "channel": "share_button",
        "request": "POST /api/shares",
        "auth_user": user,  # in the app: resolved from the Bearer session token
        "body": {
            "url": url,
            "shared_text": url,
            "client_share_id": str(uuid.UUID(int=n)),
            "shared_at": when.isoformat(timespec="minutes"),
        },
    }


def _dm_webhook(sender: str, post_path: str, when: datetime, n: int) -> dict:
    url = f"https://www.instagram.com/{post_path}/"
    shortcode = post_path.split("/")[-1]
    kind = "ig_reel" if post_path.startswith("reel/") else "ig_post"
    payload = {"url": url}
    if kind == "ig_reel":
        payload["reel_video_id"] = shortcode
    ts = int(when.timestamp() * 1000)
    return {
        "channel": "dm",
        "request": "POST /webhooks/instagram",
        "body": {
            "object": "instagram",
            "entry": [{
                "id": SOUS_IG_ID,
                "time": ts,
                "messaging": [{
                    "sender": {"id": sender},
                    "recipient": {"id": SOUS_IG_ID},
                    "timestamp": ts,
                    "message": {
                        "mid": f"sim_mid_{n:03d}_{shortcode}",
                        "attachments": [{"type": kind, "payload": payload}],
                    },
                }],
            }],
        },
    }


def generate(cast_path: Path, out_dir: Path) -> list[dict]:
    """Write one JSON file per incoming save, spread over a few evenings, and return them in time order."""
    cast = json.loads(cast_path.read_text())
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.json"):
        old.unlink()
    events, n = [], 0
    for u_i, user in enumerate(cast["users"]):
        posts = [p for chef_posts in user["follows"].values() for p in chef_posts]
        posts += user.get("resends", [])
        for p_i, post in enumerate(posts):
            when = START + timedelta(days=p_i // 3, hours=u_i, minutes=7 * p_i)
            n += 1
            if user["saves_via"] == "share_button":
                ev = _share_button(user["name"], post, when, n)
            else:
                ev = _dm_webhook(igsid(user["name"]), post, when, n)
            ev["_at"] = when.isoformat()
            events.append(ev)
    events.sort(key=lambda e: e["_at"])
    for i, ev in enumerate(events, 1):
        (out_dir / f"{i:03d}-{ev['channel']}.json").write_text(json.dumps(ev, indent=2))
    return events


def users(cast_path: Path) -> list[dict]:
    """Sous users, with the IGSID linked for people who use the DM path."""
    cast = json.loads(cast_path.read_text())
    return [{"name": u["name"], "igsid": igsid(u["name"]) if u["saves_via"] == "dm" else None}
            for u in cast["users"]]
