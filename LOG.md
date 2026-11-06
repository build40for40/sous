# Sous build log

What's happening in the codebase, newest last. Times are UK.

## Friday 6 November 2026

- **10:58** Repo starts with just `AGENTS.md` and `.gitignore` (commit `cba26d4`).
- **10:59** Superthread `day5`: created [Scaffold the Flutter app with tests and CI](https://app.superthread.com/40for40/card-178-scaffold-the-flutter-app-with-tests-and-ci) and [Publish Sous to the App Store and Google Play](https://app.superthread.com/40for40/card-179-publish-sous-to-the-app-store-and-google-play) (27-item store checklist).
- **11:05** Installed Flutter 3.47.9 on the build Mac via Homebrew. No Android SDK or full Xcode on this machine yet, so platform builds only run in CI.
- **11:08** `flutter create --empty`: iOS + Android app, placeholder screen, app ID `com.build40for40.sous` (placeholder). Flutter version pinned in `pubspec.yaml`.
- **11:10** Added a widget smoke test, Flutter entries in `.gitignore`, README.
- **11:10** Added CI: `ci.yml` (format, analyze, test, Android debug build, iOS no-codesign build on every PR) and `build.yml` (release APK/AAB + unsigned iOS app on every merge to `main`, kept 30 days).
- **11:15** Opened [PR #1](https://github.com/build40for40/sous/pull/1). All 3 checks green. Auto-fix turned on.
- **11:21** Merged PR #1 into `main` (`12c45f5`). Scaffolding task moved to Done.
- **11:26** First build on `main` passed: `sous-android-1` (60 MB) and `sous-ios-unsigned-1` (5 MB) attached to the [run](https://github.com/build40for40/sous/actions/runs/42209668434).
- **11:35** Started this log (`LOG.md`), committed straight to `main`.
