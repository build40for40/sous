# Sous

Day 5 of 40 for 40: a screen-free sous chef that talks you through the recipes you saved on Instagram. Flutter app for iOS and Android. The app has sign-in and a client for the brain, but no screens yet.

## Layout

```
apps/mobile/          Flutter app: sign-in, the brain API client and the headless cooking session (see below)
workers/brain/        Worker and UserBrain Durable Object: auth, /me, /recipes, live cooking sessions, post-cook reflection, /history and /suggest
workers/web/          landing page at build40for40.com/sous (empty)
workers/extract/      Worker for /shares: shared Instagram links, recipe pages and screenshots into recipes in the brain
packages/contracts/   recipe and session JSON Schemas and the cooking tools
.github/workflows/    CI, filtered by path
```

## Setup

The Flutter commands below run from `apps/mobile/`.

```sh
brew install --cask flutter   # Flutter version is pinned in apps/mobile/pubspec.yaml
cd apps/mobile
flutter pub get
```

iOS builds need full Xcode (plus CocoaPods); Android builds need Android Studio or the Android SDK with Java 17.

## Commands

```sh
flutter run                       # run on a connected device or simulator
flutter test                      # unit and widget tests
flutter analyze                   # lint
dart format .                     # format
```

## App plumbing

`apps/mobile/lib` has no product UI yet; screens build on these:

- `auth/`: sign-in with the shared build40for40 WorkOS AuthKit application (production, public client id in `config.dart`). `AuthController` opens hosted AuthKit in the system browser (ASWebAuthenticationSession on iOS, Auth Tab or Custom Tabs on Android) with PKCE, takes the `sous://auth/callback` redirect, exchanges the code with the verifier (no secret ships in the app), keeps the tokens in the Keychain or Keystore, refreshes them a minute before they expire, and signs out. Its `states` stream is `AuthRestoring`, `SignedOut` (with an optional `AuthError`), `SigningIn` or `SignedIn`.
- `api/`: `BrainClient`, a typed client for every route in `workers/brain/README.md`, with models matching `packages/contracts`. It sends the access token, refreshes once on a 401, and throws `BrainException` whose `error` is one of `signedOut`, `sessionEnded`, `turnInProgress`, `toolResultsRequired`, `notFound`, `invalid`, `unavailable`, `retryable` or `network`. `takeTurn` parses the `/turns` server-sent events into `StreamEvent`s.
- `cooking/`: `CookingSession` runs one cook headless. `start`, `say` and `end` drive it; `states` streams a `CookingState` (phase, stage, step, view, Sou's reply so far, transcript, error) and `replyText` streams Sou's words for speech. Sou's client tools run through a `CookingTools` implementation the app supplies (timers, step, stage, show), and all their results go back to the brain together. A turn that didn't get through leaves the phase at `interrupted`, so the cook can just say it again.
- `cooking/` also has `CookingSession.interrupt()`, which cuts off a reply that's streaming. `say()` waits out the brain finishing a reply that was cut off, so the cook's next words aren't lost.
- `voice/`: Sous's ears and mouth, all on the phone. `VoiceLoop` hears the cook, sends what they said to a `CookingSession`, and speaks the reply sentence by sentence while it streams, with numbers and units written out as words (`speakable`). It only knows the `AudioIO`, `SpeechToText` and `TextToSpeech` interfaces; `Voice.fromConfig` in `voice.dart` is the one place engines are picked. Sous hears through sherpa_onnx (Silero VAD, Moonshine v2 and the "Hey Sous" keyword spotter) with `record`, and its models download on first run (about 130 MB) through `ModelDownloader`. It speaks with the phone's own text to speech through `flutter_tts` (Google's on Android, Apple's on iPhone, preferring an installed UK voice), rendering each sentence to a WAV and playing it through `audioplayers` on the loudspeaker. `--dart-define=SOUS_SPEECH_VOICE=sherpa` switches back to Kitten on Android and Kokoro on iPhone through sherpa_onnx, which stay silent until sherpa_onnx can phonemise again (2.0.1 dropped espeak-ng) and add their model to the download. Following the voice protocol, a tap on the flame (`silence()`) or "Hold", "Wait", "Stop" or "Hey Sous" stop Sous mid-sentence without cancelling the reply, so its timers and steps still happen, and anything else the chef says goes to Sous once that reply is done. Half duplex is the default: while Sous talks, everything except those stop words is ignored as Sous's own echo. `--dart-define=SOUS_FULL_DUPLEX=true` turns on barge-in, where any speech silences Sous, and `--dart-define=SOUS_LIGHT_VOICE_MODELS=true` swaps in Moonshine tiny.
- `shares/`: sharing into Sous (Instagram's Share → Sous, or any app). `SystemShareReceiver` takes what the system share sheet sends (links and text as text, screenshots as files) through `receive_sharing_intent`. `ShareInbox` keeps each share in `FilePendingShareStore` until it reaches `workers/extract`, so shares made while signed out or offline survive restarts and go once the cook is signed in. It follows a share while it's `reading` and streams every share's status (`reading`, `saved`, `needsScreenshot`, `noRecipe`, `skipped`) for the screens; a `saved` share's `recipeId` is the recipe in the brain. `retry` re-sends a `needs_screenshot` link (the server reads it again) and `addScreenshot` rescues one with a screenshot (only accepted for that status). Screenshots are downscaled under the API's 1.9 MB limit first (`prepareScreenshot`). `SharesClient` is the typed client for `/shares`; its `ShareException.error` is one of `signedOut`, `unsupportedLink`, `dailyLimit`, `unavailable`, `inProgress`, `screenshotNotNeeded`, `imageTooLarge`, `notFound`, `invalid`, `retryable` or `network`.
- `services.dart` wires them together, and `main.dart` restores the session at start-up and starts taking shares. `SousServices.deleteAccount()` deletes in the order the servers need: the cook's shares first (`DELETE /shares`, which needs a live session), then the brain and WorkOS user, then signs out. Screens get the voice from `services.voice`: `prepare()` downloads the models with progress, then `loopFor(session)` gives a loop to `start()`, `stop()`, `silence()` and `interrupt()` (which also cancels the reply), with its `states` to watch.

### Sharing into Sous

- **Android:** `MainActivity` takes `ACTION_SEND` for `text/plain` (links) and `image/*` (screenshots), labelled "Save to Sous".
- **iOS:** the `ShareExtension` target (`ios/ShareExtension/`) accepts a link, text or one image. It writes it to the app group `group.com.build40for40.sous` in `receive_sharing_intent`'s format and opens Sous with `ShareMedia-com.build40for40.sous:share`, where the plugin picks it up. It's a plain Swift view controller rather than the plugin's `RSIShareViewController`, which only ships as a Swift package the extension can't link without Xcode. Both targets carry the app group in their entitlements (`CUSTOM_GROUP_ID`).
- **Before a signed iOS build:** register the App Group `group.com.build40for40.sous` and the extension's App ID `com.build40for40.sous.ShareExtension` in the Apple Developer account, and enable App Groups on both App IDs. CI builds without signing, so it doesn't need them.

Tests never reach WorkOS or the brain: `http`'s `MockClient` stands in for both, and the model tests read the examples in `packages/contracts`. The voice tests run `VoiceLoop` against fake engines; real audio can only be checked on a phone.

## CI

- `.github/workflows/ci.yml` runs on PRs and pushes to `main` that touch `apps/mobile/`, `packages/contracts/examples/` or the workflow itself: format check, analyze, tests, then an Android debug build and an iOS build without codesigning.
- `.github/workflows/build.yml` runs on merges to `main` that touch `apps/mobile/` or the workflow itself (or manually): release APK + AAB and an unsigned iOS `Runner.app`, uploaded as workflow artifacts for 30 days. The build number is the workflow run number.
- `.github/workflows/contracts.yml` runs on PRs and pushes to `main` that touch `packages/contracts/` or the workflow itself: typecheck and tests. See `packages/contracts/README.md`.
- `.github/workflows/brain.yml` runs on PRs and pushes to `main` that touch `workers/brain/`, `packages/contracts/` or the workflow itself: typecheck and tests. See `workers/brain/README.md`.
- `.github/workflows/brain-deploy.yml` deploys `workers/brain` to build40for40.com/sous/api on pushes to `main` that touch `workers/brain/`, `packages/contracts/` or the workflow itself (or manually). See `workers/brain/README.md`.

Signing and store upload aren't wired yet. That checklist lives on the Superthread `day5` board ("Publish Sous to the App Store and Google Play").
