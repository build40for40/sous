# Sous

Day 5 of 40 for 40: get recipes out of Instagram and into a phone app you can cook from. Flutter app for iOS and Android. Right now it's an empty scaffold.

## Setup

```sh
brew install --cask flutter   # Flutter version is pinned in pubspec.yaml
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

- `.github/workflows/ci.yml` runs on every PR: format check, analyze, tests, then an Android debug build and an iOS build without codesigning.
- `.github/workflows/build.yml` runs on every merge to `main` (or manually): release APK + AAB and an unsigned iOS `Runner.app`, uploaded as workflow artifacts for 30 days. The build number is the workflow run number.

Signing and store upload aren't wired yet. That checklist lives on the Superthread `day5` board ("Publish Sous to the App Store and Google Play").
