# Sous

Day 5 of 40 for 40, built live on Twitch on Friday 6 November 2026. The problem is "Recipes stuck on Instagram", from Mac, who sponsored it.

- **Form factor:** a Flutter phone app for iOS and Android. Setup, commands and CI are in `README.md`.
- **Layout:** a monorepo. The Flutter app lives in `apps/mobile/` (run Flutter commands from there); `packages/contracts` holds the recipe and session JSON Schemas and the cooking tools that extraction, the brain and the app share (see its README); `workers/brain` is the brain Worker with one `UserBrain` Durable Object per user, which also runs the live cooking sessions with Claude and files each cook into the user's vault afterwards (see its README); `workers/web` and `workers/extract` are placeholders. CI workflows are filtered by path, so each runs only when its component changes.
- **Tracking:** the Superthread `day5` board, the "Day 5 - Sous" page, and the "Day 5 - brief & prep" page with the kickoff notes.

Shared 40 for 40 context lives in `../AGENTS.md`.

## The problem

I have thousands of recipes saved on Instagram that I always want to try, but I forget because I don’t want to be on Instagram all the time, especially when cooking. How can I export all my saved recipes into an app or folder in writing, instead of videos, so it's easy for me to pick and follow the recipe without being on Instagram?

## What we're building

Sous ("Hey Sous") is a screen-free sous chef: an audio companion on your phone for home cooks who want the creativity back in cooking. Sous talks you through a recipe you saved on Instagram, so your hands can stay messy and your eyes stay on the food.

The cook moves through five states in a loop: decide, prep (mise en place), cook, present, feedback, then back to decide.

## Workstreams

Each one has a card on the `day5` board.

- **Extraction:** turn an Instagram post (caption, video frames, audio) into a structured recipe with ingredients and amounts, steps, and what "done" looks like. Instagram has no API for saved posts, and fetching posts from links is scraping, which breaks Instagram's terms. Check with the team before building on it.
- **Brain:** one continuous voice conversation per recipe, with the recipe and the cook's preferences as context. The prompt sets out rough stages rather than a fixed decision tree, so the cook can go off script. Whatever it learns is saved back at the end. Model API keys never ship in the app.
- **App:** the user states, what the cook sees and hears in each one, and the visual skin.

The recipe format links extraction to the brain, and the session format links the brain to the app. Agree any change to either with the workstream on the other side.

## Decided

UX decisions from Lawrence, who owns the app:

- The app and the assistant are both called Sous, as in sous chef. People may say it like "Sue", and that's fine, but it's never written "Sou".
- The screen stays awake for the whole cooking session and goes back to normal when the session ends.
- The app's background is mostly black, to save battery and so the phone sits quietly on the counter.
- Talking to Sous works like a professional kitchen. The cook is the head chef and Sous is the sous chef, so every instruction gets an acknowledgement, the way cooks answer "Heard" or "Yes, Chef". It works in both directions: whoever receives an instruction acknowledges it.
- The chef opens a turn by saying the wake word "Hey Sous" or by tapping the flame. Saying "Sous" alone doesn't open one. The wake word is said like "Hey Sue", so it should also respond to close variants such as "Hey Sue" and "Hey Sue Chef". Nothing else in the room, like the TV or the kids, opens a turn.
- When the chef speaks, a pause ends the turn, as with any voice assistant. The chef never has to say "Yes, Chef" to finish their own sentence. Sous waits a little longer than usual (about a second, to tune), and longer still when the sentence sounds unfinished ("I want to cook a…"). Sous then calls it back, "Heard, Chef. Bolognese.", so the chef knows it understood. If Sous cut in too early, the chef just keeps talking or says "Hold".
- When Sous gives an instruction, the chef closes it with "Heard", "Yes, Chef" or any natural acknowledgement, such as "Understood, Chef", "Yep" or "Got it". This is the only time the chef's acknowledgement closes anything. A reply that adds something ("Yep, but make it ten") is a new instruction, not an acknowledgement.
- If the chef doesn't acknowledge an instruction, Sous repeats it like an alarm clock: urgent enough to notice, not so often it's annoying. It repeats after about 10 seconds, again after about 30, then every minute, each time shorter ("Chef, rice, twelve minutes. Heard?"). These intervals are a starting point to tune with real cooks.
- Sous never speaks first. When it needs the chef, such as when a timer finishes, the flame turns from blue to red and a short chime plays. The chime repeats gently until the chef says "Hey Sous" or taps the flame. Then Sous says what it needs and waits for an acknowledgement.
- "Hold", "Wait", "Stop" and "Hey Sous" stop Sous mid-sentence, straight away. They only silence Sous and never cancel timers or skip steps. Anything looser the chef says is picked up once Sous has paused. Sous gives one instruction per sentence and pauses for an acknowledgement, so there's rarely a long speech to cut into.
- Sous calls the cook "Chef" and offers rather than tells ("Chef, the recipe says twelve minutes. Set it?"). It never says "you should".
- The recipe picker is a numbered list, so the cook can choose by voice ("Hey Sous, number three"). It shows one hint of what to say.
- The face of Sous on the cook screen is a burner: a ring of blue gas flame on black. It's also the listening light and the talk button. The flame is low while waiting, bounces while the chef is speaking, flickers while Sous thinks and surges while Sous talks. It turns red when Sous needs the chef. Tapping it does the same as saying "Hey Sous".
- A small line under the flame says what to do. While waiting it reads "Waiting for instructions. Say "Hey Sous" or tap the flame." When the flame is red it reads "Sous needs you. Say "Hey Sous" or tap the flame."
- Several timers can run at once, each named after what's cooking ("rice", "dahl"). Sous sets them by voice, and the app runs them, so they keep working if the brain drops out. They stack under the burner, change colour as they get close, and show on the lock screen. A finished timer turns the same red as the flame.
- "Game plan" is the name for Sous planning the cook with you, which is separate from prep (mise en place). A retro after the cook, which you can also add to later, such as the next day from the sofa ("it was too salty"), is a stretch goal.

## Still open

Don't record architecture, design or tech choices here until the team has made them.

- Whether there are any screens outside cooking, for browsing saved recipes and picking one
- The rest of the app's look and feel
- Where preferences and feedback are stored

Ideas from kickoff, not commitments: prep reminders (dice the spring onions before your hands get messy), cooking with the fewest utensils, presentation tips, and a physical device such as an e-ink screen.
