# Contributing

Thanks for taking the time. Issues and pull requests are both welcome.

## Before you start

- Read [COMMUNITY.md](COMMUNITY.md). It describes what this app is for, and the two or
  three kinds of change that will not be accepted no matter how well written.
- For anything larger than a bug fix, open an issue first. It is much cheaper to disagree
  about an approach in an issue than in a diff.

## Working in the repository

Each client lives in its own directory and builds on its own. A change usually belongs to
one of them:

| Directory | Toolchain | Build |
|---|---|---|
| `web/` | Node 22 | `npm install && npm run build:app` |
| `ios/` | Xcode 16+ | open `ios/Oriveo/Oriveo.xcodeproj` |
| `android/` | JDK 17+ | `./gradlew :app:assembleDebug` |
| `shared/OriveoProviderKit/` | Swift 6 | `swift build && swift test` |

`shared/model-contracts`, `shared/capabilityrecipe`, and `shared/test-fixtures` are shared
by more than one client. If you change one of those files, run the contract tests of every
client that reads it, not just the one you are working in.

## Tests

Please include a test with a behavior change, and run the suite for what you touched:

```bash
cd web && npm run test:run && npm run typecheck
cd shared/OriveoProviderKit && swift test
```

For a provider protocol fix, prefer a recorded fixture under `shared/test-fixtures` over a
hand-written mock. A real byte stream from the provider is what makes these tests worth
having.

## Style

- Source, comments, tests, and commit messages are written in English.
- Interface strings are translated. Add a new string to `en` first and leave the other
  locales to follow; do not hand-translate sixteen files in the same pull request.
- Match the surrounding code. There is no separate formatting pass to hide behind.
- Explain *why* in a comment, not *what*. The code already says what.

## Commits and pull requests

- Keep a pull request to one reviewable change.
- Write a commit message that says what changed and why. If it fixes a reported problem,
  describe how you reproduced it.
- A pull request that touches a provider's request or response handling should say which
  provider and model you tested it against.

## License

Contributions are accepted under AGPL-3.0-or-later, the same license as the repository.
