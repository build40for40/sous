# Sous

Day 5 of 40 for 40: a screen-free sous chef that talks you through the recipes you saved on Instagram. Flutter app for iOS and Android. Right now it's an empty scaffold.

## Layout

```
apps/mobile/          Flutter app
workers/brain/        Worker and UserBrain Durable Object: auth, /me and /recipes
workers/web/          landing page at build40for40.com/sous (empty)
workers/extract/      extraction, if it needs a server (empty)
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
flutter test                      # widget tests
flutter analyze                   # lint
dart format .                     # format
```

## CI

- `.github/workflows/ci.yml` runs on PRs and pushes to `main` that touch `apps/mobile/` or the workflow itself: format check, analyze, tests, then an Android debug build and an iOS build without codesigning.
- `.github/workflows/build.yml` runs on merges to `main` that touch `apps/mobile/` or the workflow itself (or manually): release APK + AAB and an unsigned iOS `Runner.app`, uploaded as workflow artifacts for 30 days. The build number is the workflow run number.
- `.github/workflows/contracts.yml` runs on PRs and pushes to `main` that touch `packages/contracts/` or the workflow itself: typecheck and tests. See `packages/contracts/README.md`.
- `.github/workflows/brain.yml` runs on PRs and pushes to `main` that touch `workers/brain/`, `packages/contracts/` or the workflow itself: typecheck and tests. See `workers/brain/README.md`.

Signing and store upload aren't wired yet. That checklist lives on the Superthread `day5` board ("Publish Sous to the App Store and Google Play").
