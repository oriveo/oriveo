# Contributing

Thanks for taking the time. Issues and pull requests are both welcome.

## Before you start

- Read [COMMUNITY.md](COMMUNITY.md). It describes what this app is for, and the two or three kinds
  of change that will not be accepted no matter how well written.
- For anything larger than a bug fix, open an issue first. It is much cheaper to disagree about an
  approach in an issue than in a diff.

## Working in the repository

Each client lives in its own directory and builds on its own. A change usually belongs to one of
them, and each client's README is the single place its toolchain and commands are written down:

- `web/` — [Quick start](web/README.md#quick-start) and [Commands](web/README.md#commands)
- `ios/` — [Build and run](ios/README.md#build-and-run)
- `android/` — [Building](android/README.md#building)
- `shared/OriveoProviderKit/` — [Working on these files](shared/README.md#working-on-these-files)

A native macOS client is in development and will land in [`macos/`](macos/README.md) in the coming
months. Until it is here there is nothing to build there, so please do not open a pull request that
starts one; changes to the other three clients and to `shared/` are what move it forward.

> [!IMPORTANT]
> Clone the whole repository. The test suites resolve `shared/` relative to the working
> directory, so they only pass in a full checkout, never in a partial or single-client one.

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
  -destination 'platform=iOS Simulator,name=iPhone 16'
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

Contributions are accepted under AGPL-3.0-or-later, the same license as the repository. There is no
contributor license agreement to sign and no copyright to assign: opening a pull request is taken
as agreeing that your work may be distributed under that license, and you keep the copyright in
what you wrote.
