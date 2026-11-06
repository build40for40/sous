# Sous

Day 5 of 40 for 40, built live on Twitch on Friday 6 November 2026. The problem is "Recipes stuck on Instagram", from Mac, who sponsored it.

- **Form factor:** a Flutter phone app for iOS and Android. Setup, commands and CI are in `README.md`.
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

## Decided

UX decisions from Lawrence, who owns the app:

- The screen stays awake for the whole cooking session and goes back to normal when the session ends.
- The app's background is mostly black, to save battery and so the phone sits quietly on the counter.
- Hands-free works with a wake word, "Hey Sous" (as in sous chef). It's said like "Hey Sue", so it should also respond to close variants such as "Hey Sue" and "Hey Sue Chef".
- The recipe picker is a numbered list, so the cook can choose by voice ("Hey Sous, number three"). It shows one hint of what to say.
- Sou's face on the cook screen is a burner: a ring of gas flame on black. The flame shows Sou's state: low while waiting, rising while listening, flickering while thinking, and surging while talking.
- Several timers can run at once, each named after what's cooking ("rice", "dahl"). Sou sets them by voice, and the app runs them, so they keep working if the brain drops out. They stack under the burner, change colour as they get close, and show on the lock screen.
- "Game plan" is the name for Sou planning the cook with you, which is separate from prep (mise en place). A retro after the cook, which you can also add to later, such as the next day from the sofa ("it was too salty"), is a stretch goal.

## Still open

Don't record architecture, design or tech choices here until the team has made them.

- Whether there are any screens outside cooking, for browsing saved recipes and picking one
- The rest of the app's look and feel
- Where preferences and feedback are stored

Ideas from kickoff, not commitments: prep reminders (dice the spring onions before your hands get messy), cooking with the fewest utensils, presentation tips, and a physical device such as an e-ink screen.
