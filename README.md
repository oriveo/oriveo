# Oriveo

Native AI chat for iOS, Android, and the web. Bring your own API keys.

Oriveo talks directly to the model providers you already pay for — OpenAI, Anthropic,
Gemini, OpenRouter, DeepSeek, Grok, Groq, Together, Fireworks, MiniMax, Zhipu, Qwen,
Moonshot, Mistral, SiliconFlow — plus any OpenAI-compatible relay or a model server
running on your own machine. Your keys, your conversations, and your notes stay on the
device. There is no account to create and nothing to sign in to.

This repository is Oriveo Community Edition, licensed under
[AGPL-3.0-or-later](LICENSE). The apps published on the App Store and Google Play are a
separate proprietary product that adds a hosted account, cloud sync, and managed models.

## What you get

- Chat with your own provider keys, relay endpoints, and local engines
- Device login for your own Codex or Grok subscription
- Notes, folders, and custom skills, stored locally and unlimited
- Cost estimates computed from the message history on the device
- Attachments, image generation, tool calls, and streaming reasoning where the provider
  supports them
- Sixteen interface languages

## Layout

```
ios/       iOS client (SwiftUI)
android/   Android client (Jetpack Compose)
web/       Web client (Next.js)
macos/     Reserved for the macOS client
shared/    Cross-client Swift package, wire contracts, and test fixtures
```

`shared/model-contracts` and `shared/capabilityrecipe` describe how a model's advertised
capabilities are turned into a provider request. Every client asserts against the same
JSON, so a behavior change lands in one place. `shared/test-fixtures` holds recorded
provider traffic used by the contract tests.

## Web

Requires Node 22 (see [`web/.nvmrc`](web/.nvmrc)).

```bash
cd web
npm install
npm run dev:app     # http://localhost:3001
```

Other useful commands, all run from `web/`:

```bash
npm run build:app   # production build
npm run typecheck   # tsc --noEmit across every workspace
npm run test:run    # vitest, once
npm run lint
```

Configuration is optional. Copy [`web/.env.example`](web/.env.example) to `web/.env.local`
only if you need to change a default. See [web/README.md](web/README.md).

## iOS

Requires a Mac with Xcode 16 or later and a device on iOS 18 or later. A free Apple
Developer account is enough; the app uses no paid capabilities.

Open `ios/Oriveo/Oriveo.xcodeproj`, pick the `Oriveo` scheme, choose your team under
Signing & Capabilities, and run. [ios/README.md](ios/README.md) has the full walkthrough.

## Android

Requires Android Studio and JDK 17 or later.

```bash
cd android
./gradlew :app:assembleDebug
```

See [android/README.md](android/README.md).

## macOS

The macOS client is not part of this release. See [macos/README.md](macos/README.md).

## Contributing

Bug reports and pull requests are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) first, and [COMMUNITY.md](COMMUNITY.md) for what this
edition is meant to do.

## License

[AGPL-3.0-or-later](LICENSE). Contributions are accepted under the same license.
