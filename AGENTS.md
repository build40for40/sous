# Sous

Day 5 of 40 for 40, built live on Twitch on Friday 6 November 2026. The problem is "Recipes stuck on Instagram", from Mac, who sponsored it.

- **Form factor:** a Flutter phone app for iOS and Android. Setup, commands and CI are in `README.md`.
- **Layout:** a monorepo. The Flutter app lives in `apps/mobile/` (run Flutter commands from there); `packages/contracts` holds the recipe and session JSON Schemas and the cooking tools that extraction, the brain and the app share (see its README); `workers/brain`, `workers/web` and `workers/extract` are placeholders for the backend. CI workflows are filtered by path, so each runs only when its component changes.
- **Tracking:** the Superthread `day5` board, the "Day 5 - Sous" page, and the "Day 5 - brief & prep" page with the kickoff notes.

Shared 40 for 40 context lives in `../AGENTS.md`.

## The problem

I have thousands of recipes saved on Instagram that I always want to try, but I forget because I don’t want to be on Instagram all the time, especially when cooking. How can I export all my saved recipes into an app or folder in writing, instead of videos, so it's easy for me to pick and follow the recipe without being on Instagram?

## What we're building

Sous ("Hey, Sou") is a screen-free sous chef: an audio companion on your phone for home cooks who want the creativity back in cooking. Sou talks you through a recipe you saved on Instagram, so your hands can stay messy and your eyes stay on the food.

The cook moves through five states in a loop: decide, prep (mise en place), cook, present, feedback, then back to decide.

## Workstreams

Each one has a card on the `day5` board.

- **Extraction:** turn an Instagram post (caption, video frames, audio) into a structured recipe with ingredients and amounts, steps, and what "done" looks like. Instagram has no API for saved posts, and fetching posts from links is scraping, which breaks Instagram's terms. Check with the team before building on it.
- **Brain:** one continuous voice conversation per recipe, with the recipe and the cook's preferences as context. The prompt sets out rough stages rather than a fixed decision tree, so the cook can go off script. Whatever it learns is saved back at the end. Model API keys never ship in the app.
- **App:** the user states, what the cook sees and hears in each one, and the visual skin.

The recipe format links extraction to the brain, and the session format links the brain to the app. Agree any change to either with the workstream on the other side.

## Still open

Don't record architecture, design or tech choices here until the team has made them.

- Whether there are any screens outside cooking, for browsing saved recipes and picking one
- How hands-free works: a voice button, a session that keeps listening, or a wake word
- The app's look and feel
- Where preferences and feedback are stored

Ideas from kickoff, not commitments: prep reminders (dice the spring onions before your hands get messy), cooking with the fewest utensils, presentation tips, and a physical device such as an e-ink screen.
