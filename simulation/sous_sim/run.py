"""Run the simulation end to end: `uv run sous-sim` from simulation/.

Safe to re-run. Stage 1 (saves) is replayed from scratch each time; fetched posts
and extracted recipes are kept. With the default RECIPE_MODEL=claude-code-handoff,
the first run stops after writing extraction requests; once Claude Code has
written the responses, run it again to finish.
"""

from __future__ import annotations

from collections import Counter
from pathlib import Path

from . import extract, fetch, incoming, render, store

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "work"
OUT = ROOT / "output"


def main() -> None:
    db = store.connect(WORK / "sous.db")

    print("1. Saves arriving (share button + DMs to @sous)")
    events = incoming.generate(ROOT / "cast.json", WORK / "incoming")
    store.add_users(db, incoming.users(ROOT / "cast.json"))
    replies = Counter(r for ev in events for r in store.ingest(db, ev))
    channels = Counter(ev["channel"] for ev in events)
    print(f"   {len(events)} saves ({dict(channels)}) → {dict(replies)}")

    print("2. Fetching posts (caption, recipe page, audio, frames)")
    fetch.fetch_all(db, WORK / "media")

    print("3. Writing recipes with Claude")
    _, pending = extract.extract_all(db, WORK)

    print("4. Writing each person's recipes")
    render.render(db, OUT)
    print(f"   → {OUT}")
    if pending:
        print(f"\n{pending} extraction requests are waiting in {WORK / 'handoff' / 'requests'}. "
              "Write the responses, then run again.")


if __name__ == "__main__":
    main()
