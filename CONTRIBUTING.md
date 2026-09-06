# Contributing

Thanks for taking the time. Issues and pull requests are both welcome.

## Before you start

- Read [COMMUNITY.md](COMMUNITY.md). It describes what this app is for, and the two or three kinds
  of change that will not be accepted no matter how well written.
- For anything larger than a bug fix, open an issue first. It is much cheaper to disagree about an
  approach in an issue than in a diff.

## Working in the repository

Each client lives in its own directory and builds on its own. A change usually belongs to one of
them:

| Directory | Toolchain | Build |
|---|---|---|
| `web/` | Node 22 | `npm install && npm run build:app` |
| `ios/` | Xcode 26 | open `ios/Oriveo/Oriveo.xcodeproj` |
| `android/` | JDK 21, Android SDK | `./gradlew :app:assembleDebug` |
| `shared/OriveoProviderKit/` | Swift 6.1 | `swift build && swift test` |

Each client's README covers its architecture and the details of building it:
[iOS](ios/README.md) · [Android](android/README.md) · [Web](web/README.md) ·
[Shared](shared/README.md).

> [!IMPORTANT]
> Clone the whole repository. All three clients load contract fixtures from `shared/` by resolving
> a path relative to the repository root, so their test suites do not pass in a partial checkout.

`shared/model-contracts`, `shared/capabilityrecipe`, and `shared/test-fixtures` are read by more
than one client. If you change one of those files, run the contract tests of every client that
reads it, not just the one you are working in.

## Tests

Please include a test with a behaviour change, and run the suite for what you touched:

Each block below runs from the repository root:

```bash
# Web
(cd web && npm run test:run && npm run typecheck)

# Shared Swift package
(cd shared/OriveoProviderKit && swift test)

# Android
(cd android && ./gradlew :app:testDebugUnitTest)

# iOS — substitute a simulator you have (xcrun simctl list devices available)
xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

For a provider protocol fix, prefer a recorded fixture under `shared/test-fixtures` over a
hand-written mock. A real byte stream from the provider is what makes these tests worth having.

## Style

- Source, comments, tests, and commit messages are written in English.
- Interface strings are translated into sixteen locales. Add a new string to the English source
  first and leave the others to follow; do not hand-translate sixteen files in the same pull
  request.
- Match the surrounding code. There is no separate formatting pass to hide behind.
- Explain *why* in a comment, not *what*. The code already says what.

## Documentation

The root and client READMEs are translated into fifteen other languages under `readme_i18n/` — a
separate set from the sixteen locales the app's interface ships in. If you change an English README,
you do not have to update all fifteen translations: say so in the pull request and they will be
brought back into line. Do not machine-translate them in bulk.

## Commits and pull requests

- Keep a pull request to one reviewable change.
- Write a commit message that says what changed and why. If it fixes a reported problem, describe
  how you reproduced it.
- A pull request that touches a provider's request or response handling should say which provider
  and model you tested it against.

## Security

Please do not open a public issue for a security problem. [SECURITY.md](SECURITY.md) explains how
to report one privately.

## License

Contributions are accepted under AGPL-3.0-or-later, the same license as the repository.
