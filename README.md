<div align="center">

<img src="docs/assets/logo.png" width="104" height="104" alt="Oriveo logo">

# Oriveo Community Edition

**Every model, one app.**

Open-source, bring-your-own-key AI chat for iOS, Android, and the web,
with a native macOS client in development.
No account, no subscription, and no service of ours in the request path.

<a href="LICENSE"><img alt="License AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<a href="ios/README.md"><img alt="iOS 18 and later" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white"></a>
<a href="android/README.md"><img alt="Android 8 and later" src="https://img.shields.io/badge/Android-8+-A78BFA?style=flat-square&labelColor=black&logo=android&logoColor=white"></a>
<a href="web/README.md"><img alt="Web built with Next.js" src="https://img.shields.io/badge/Web-Next.js-A78BFA?style=flat-square&labelColor=black&logo=nextdotjs&logoColor=white"></a>
<a href="macos/README.md"><img alt="macOS client in development" src="https://img.shields.io/badge/macOS-in_development-6D5FA6?style=flat-square&labelColor=black&logo=apple&logoColor=white"></a>
<img alt="15 providers plus relay" src="https://img.shields.io/badge/providers-15_+_relay-8B5CF6?style=flat-square&labelColor=black">
<img alt="16 interface languages" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

**Get Oriveo:**
<a href="https://oriveoai.com"><b>oriveoai.com</b></a> &nbsp;·&nbsp;
<a href="https://apps.apple.com/app/oriveo/id6775370458">App Store</a> &nbsp;·&nbsp;
<a href="https://play.google.com/store/apps/details?id=com.kenny.oriveo">Google Play</a> &nbsp;·&nbsp;
<a href="https://app.oriveoai.com">Web app</a>

<a href="#get-started">Build from source</a> &nbsp;·&nbsp;
<a href="#architecture">Architecture</a> &nbsp;·&nbsp;
<a href="#community-edition-and-oriveo">Editions</a> &nbsp;·&nbsp;
<a href="#faq">FAQ</a> &nbsp;·&nbsp;
<a href="CONTRIBUTING.md">Contributing</a>

<sub>

**English** ·
<a href="readme_i18n/ar/README.md">العربية</a> ·
<a href="readme_i18n/de/README.md">Deutsch</a> ·
<a href="readme_i18n/es/README.md">Español</a> ·
<a href="readme_i18n/fr/README.md">Français</a> ·
<a href="readme_i18n/hi/README.md">हिन्दी</a> ·
<a href="readme_i18n/id/README.md">Indonesia</a> ·
<a href="readme_i18n/ja/README.md">日本語</a> ·
<a href="readme_i18n/ko/README.md">한국어</a> ·
<a href="readme_i18n/pt-BR/README.md">Português</a> ·
<a href="readme_i18n/ru/README.md">Русский</a> ·
<a href="readme_i18n/th/README.md">ไทย</a> ·
<a href="readme_i18n/tr/README.md">Türkçe</a> ·
<a href="readme_i18n/vi/README.md">Tiếng Việt</a> ·
<a href="readme_i18n/zh-Hans/README.md">简体中文</a> ·
<a href="readme_i18n/zh-Hant/README.md">繁體中文</a>

</sub>

</div>

---

## What Oriveo is

Oriveo Community Edition is an open-source, bring-your-own-key (BYOK) AI chat client for iOS,
Android, and the web, with a native macOS client in development. It is for people who would rather
pay a model provider directly than pay a subscription to whatever sits in front of it: you supply
API keys you already own, and the client talks to the provider with them. That makes it a
local-first, multi-model alternative to a hosted ChatGPT or Claude plan — no Oriveo account, no
subscription, nothing reporting back to us, and a web client you can self-host.

It speaks to **15 model providers** natively — OpenAI, Anthropic, Google Gemini, OpenRouter,
DeepSeek, Grok, Mistral, Groq, Together AI, Fireworks AI, MiniMax, Z.ai, Qwen, Kimi (Moonshot) and
SiliconFlow — plus **any OpenAI-, Anthropic- or Gemini-compatible endpoint** you point it at,
including llama.cpp, Ollama, LM Studio or vLLM running on your own machine.

| | |
|---|---|
| **Providers** | 15 built in, plus custom relay endpoints and local model servers |
| **Clients** | iOS (SwiftUI) · Android (Jetpack Compose) · Web (Next.js) · macOS in development |
| **Interface languages** | 16 |
| **Account required** | None |
| **Calls it makes on its own behalf** | One thing, in two requests: a read-only model catalog, carrying no key and no identifier we attach |
| **License** | AGPL-3.0-or-later |

## Why it exists

Nobody should be able to meter, log, or mark up the model you are paying for.

- **Your keys, your bill.** You pay the provider's list price. Nothing is marked up, metered, or
  resold.
- **Local by default.** Conversations, notes, folders, skills, and attachments live on the device.
  Export them to a file whenever you want; there is no cloud copy to lose access to.
- **One behaviour, three clients.** How a request is shaped for a given provider, transport, and
  capability is written down once in [`shared/`](shared/README.md), and all three clients assert
  against the same JSON fixtures. A quirk that lives in that data is fixed once; one that lives in a
  parser is caught by three suites at the same time.
- **The one thing it fetches.** The app reads a public model catalog so that a model released
  today works without an app update. Both of its requests are read-only and carry no key and no
  identifier we attach, and the web and Android clients can be pointed at a host of your own.

## Features

- **Chat** — streaming, reasoning blocks, citations, attachments (images and video, PDF, Office
  (docx, xlsx, pptx), OpenDocument, EPUB, RTF, HTML, and any plain-text or source file), quote-a-selection,
  retry, regenerate, continue after an interrupted answer
- **Providers** — 15 built in, each with your own key; per-provider model and generation-parameter
  overrides, and a choice of regional endpoint where the provider offers one
- **Relay** — any OpenAI-, Anthropic- or Gemini-compatible endpoint, including one on your LAN
- **Local model servers** — llama.cpp, Ollama, LM Studio, vLLM, Open WebUI; iOS and Android find
  them on the local network over mDNS
- **Subscription sign-in** — use a ChatGPT or Grok subscription you already hold instead of an
  API key, over each provider's own device-authorization flow
- **Skills** — reusable system prompts with their own model, reasoning setting, and reference
  documents
- **Notes and folders** — capture a reply as a note, organise conversations, search across both
- **Cross-check** — hand an answer to a second model for review and keep the two together
- **Cost** — per-message and per-provider spend, computed on the device from what each response
  actually reported, including the cache read and cache write tiers
- **Image generation** — where the provider supports it
- **Backup** — export everything to a file; the provider keys in it, if you choose to include them,
  are encrypted with a password of yours
- **16 interface languages**, including full right-to-left layout for Arabic

## Community Edition and Oriveo

This repository is **Oriveo Community Edition**, licensed under
[AGPL-3.0-or-later](LICENSE). The apps on the App Store, Google Play, and the hosted web app are
**Oriveo** — a separate proprietary product built from the same clients, with an account layer on
top.

| | Community Edition | Oriveo |
|---|---|---|
| Source | This repository, AGPL-3.0-or-later | Proprietary |
| Chat with your own provider keys | Yes | Yes |
| Relay and local model servers | Yes | Yes |
| Notes, folders, skills, attachments | Yes | Yes |
| On-device cost tracking | Yes | Yes |
| Account | None | Oriveo account |
| Storage | On the device; manual export and restore | Local-first, plus cross-device cloud sync |
| Usage insights and budget alerts | — | Yes |
| Models paid for by Oriveo | — | Yes |
| Analytics and crash reporting | None. The web bundle carries Sentry, silent until you set a DSN of your own | Yes |

Community Edition builds use the `ai.oriveo.community` identifier prefix, so one can sit on the
same device as a store build without the two sharing a keychain or any local data. What this
edition will and will not accept is written down in [COMMUNITY.md](COMMUNITY.md).

**Oriveo, the full product:**
[iPhone and iPad](https://apps.apple.com/app/oriveo/id6775370458) &nbsp;·&nbsp;
[Android](https://play.google.com/store/apps/details?id=com.kenny.oriveo) &nbsp;·&nbsp;
[Web](https://app.oriveoai.com) &nbsp;·&nbsp;
[oriveoai.com](https://oriveoai.com)

## Providers

Every provider below is reached with a key you create yourself. Two of them can also be reached by
signing in with a subscription you already hold instead of a key: OpenAI with a ChatGPT plan, and
Grok.

| Provider | Where to get a key |
|---|---|
| OpenAI | [platform.openai.com](https://platform.openai.com/api-keys) |
| Anthropic | [platform.claude.com](https://platform.claude.com/settings/keys) |
| Google Gemini | [aistudio.google.com](https://aistudio.google.com/apikey) |
| OpenRouter | [openrouter.ai](https://openrouter.ai/keys) |
| DeepSeek | [platform.deepseek.com](https://platform.deepseek.com/api_keys) |
| Grok | [console.x.ai](https://console.x.ai/) |
| Mistral | [console.mistral.ai](https://console.mistral.ai/api-keys) |
| Groq | [console.groq.com](https://console.groq.com/keys) |
| Together AI | [api.together.xyz](https://api.together.xyz/settings/api-keys) |
| Fireworks AI | [fireworks.ai](https://fireworks.ai/api-keys) |
| MiniMax | [platform.minimax.io](https://platform.minimax.io/docs/guides/quickstart-preparation) |
| Z.ai | [open.bigmodel.cn](https://open.bigmodel.cn/usercenter/apikeys) |
| Qwen | [bailian.console.alibabacloud.com](https://bailian.console.alibabacloud.com/?apiKey=1#/api-key) |
| Kimi (Moonshot) | [platform.kimi.ai](https://platform.kimi.ai/console/api-keys) |
| SiliconFlow | [cloud.siliconflow.cn](https://cloud.siliconflow.cn/account/ak) |
| **Relay** | Any OpenAI-, Anthropic- or Gemini-compatible endpoint, including one on your own machine |

## Architecture

Three native clients, one definition of how to talk to a model provider.

```mermaid
flowchart LR
    shared["shared/<br/>request recipes · contracts · recorded fixtures"]

    subgraph clients ["Three native clients"]
        direction TB
        ios["iOS · SwiftUI"]
        android["Android · Compose"]
        web["Web · Next.js"]
    end

    route["Next.js route handler<br/>on the machine serving the app"]

    subgraph upstream ["Reached with your key"]
        official["15 model providers"]
        relay["Any compatible relay"]
        local["A server on your machine"]
    end

    catalog[("Public model catalog<br/>read-only · no key")]

    shared -.->|"asserted by every client"| clients
    catalog -.->|"capabilities and prices"| clients
    ios & android ==>|"straight from the device"| upstream
    web ==> route ==> upstream
```

Each client owns its own UI, storage, and navigation, and meets the shared contracts at exactly one
seam: the layer that turns *this model, this capability* into an HTTP request.

The one asymmetry worth knowing about is the web client. Most provider APIs send no CORS headers,
so a browser cannot call them directly; those requests pass through a Next.js route handler running
on whatever machine serves the app — your own, when you run it locally. The handful of endpoints
that do allow a browser (Kimi's China endpoint, the balance endpoints of a few providers) and
relays on your own network are called directly. The iOS and Android clients have no such constraint
and always go straight to the provider.

**The architecture of each client:**

| | Stack | README |
|---|---|---|
| **iOS** | SwiftUI with a UIKit transcript, GRDB | [ios/README.md](ios/README.md) |
| **Android** | Jetpack Compose, Room, Koin, Ktor/OkHttp | [android/README.md](android/README.md) |
| **Web** | Next.js App Router, React, Zustand, TypeScript | [web/README.md](web/README.md) |
| **macOS** | In development, arriving in the coming months | [macos/README.md](macos/README.md) |
| **Shared** | Contracts, recorded fixtures, and the Swift wire kernel | [shared/README.md](shared/README.md) |

## Get started

There are no prebuilt binaries here — no APK, no `.ipa`. Community Edition is source
you build yourself, and the store apps are the other product. The web client is the shortest path to
a running app.

<details open>
<summary><b>Web</b> — the quickest way to try it</summary>

<br>

Requires Node 22.22 or newer (see [`web/.nvmrc`](web/.nvmrc)).

```bash
cd web
npm install
npm run dev:app        # http://localhost:3001
```

The first screen asks for a provider API key. Nothing else is required.
More commands and configuration: [web/README.md](web/README.md).

</details>

<details>
<summary><b>iOS</b> — build and run on your own iPhone</summary>

<br>

Requires a Mac with Xcode 26 and a device on iOS 18 or later. A free Apple Developer account is
enough — the app uses no paid capabilities.

1. Open `ios/Oriveo/Oriveo.xcodeproj`
2. Select the `Oriveo` scheme
3. Under Signing &amp; Capabilities, choose your own Team
4. Run

Full walkthrough, including what to do if Xcode refuses to open the project:
[ios/README.md](ios/README.md).

</details>

<details>
<summary><b>Android</b> — build the APK</summary>

<br>

Requires JDK 21 and the Android SDK. The build uses AGP 9.3, Gradle 9.5 and Kotlin 2.3, so
Android Studio has to be a release that can sync them; from the command line only the JDK and the
SDK are needed.

```bash
cd android
./gradlew :app:assembleDebug
```

Serving the model catalog from your own host: [android/README.md](android/README.md).

</details>

## Privacy

- **Provider keys** go to the iOS Keychain, and on Android to `EncryptedSharedPreferences` under a
  key held in the Android Keystore. A browser has no equivalent facility, so on the web they sit
  unencrypted in IndexedDB — the same model browser BYOK clients generally use. For the strongest
  guarantee, use the iOS or Android client.
- **Conversations, notes, folders, skills, and attachments** are stored on the device. Nothing is
  uploaded anywhere.
- **No account, and no analytics.** There is nothing to sign in to, and nothing counts what you do.
  The web bundle includes Sentry for error reporting; it stays silent until you set
  `NEXT_PUBLIC_SENTRY_DSN` to a project of your own, and if you do, it is configured to capture
  session replays as well as stack traces. The iOS and Android clients contain no reporting SDK at
  all.
- **On iOS and Android, chat requests go straight from the device to the provider.** On the web most
  of them pass through the Next.js server that serves the app, because most provider APIs do not
  permit a direct browser call; that server does not persist keys or messages, and when you run the
  app locally it is your own machine.
- **Two requests of our own:** a read-only model catalog, read in two calls — one for how each
  model wants to be addressed, one for the facts about individual models, which iOS reads only after
  a subscription sign-in — so a model released today works without a new build. Neither carries a
  key, a conversation, or an identifier we attach. The
  web client (`NEXT_PUBLIC_BACKEND_URL`) and the Android build (`-PORIVEO_METADATA_BASE_URL`) can be
  pointed at a host of your own; on iOS that override is a Debug-build convenience only.

## FAQ

<details>
<summary><b>What does BYOK mean?</b></summary>

<br>

Bring your own key. You create an API key in a provider's own console — OpenAI, Anthropic, Google,
and so on — and paste it into Oriveo. Requests are billed by that provider at its list price.
Oriveo is the client; it is not a reseller and takes no cut.

</details>

<details>
<summary><b>Is it free?</b></summary>

<br>

The client is. It is open source under AGPL-3.0-or-later, there is nothing to subscribe to, and no
part of it is held back behind a payment. What you pay is the model provider's own list price for
the requests you make, billed by them, on the account the key belongs to. Oriveo never sees that
bill.

</details>

<details>
<summary><b>Do my conversations go through an Oriveo server?</b></summary>

<br>

No. On iOS and Android the client calls the provider endpoint directly. On the web most requests go
through the Next.js server that is serving the app — your own machine when you run it locally —
because most provider APIs refuse a direct browser call; the few that allow one are called
directly. Neither path involves a server operated by Oriveo. The only thing Oriveo fetches on its
own behalf is the public model catalog, in two read-only requests that carry no key, no
conversation, and no identifier we attach.

</details>

<details>
<summary><b>Can I use a model running on my own machine?</b></summary>

<br>

Yes. Add a Relay connection pointing at any OpenAI-, Anthropic- or Gemini-compatible server —
llama.cpp, Ollama, LM Studio, vLLM, Open WebUI, or anything else speaking one of those protocols.
The iOS and Android clients can discover one on the local network over mDNS; the web client
suggests each engine's usual address and probes it. Local HTTP uses no credential and never leaves
your network.

</details>

<details>
<summary><b>Can I run the whole thing myself?</b></summary>

<br>

Yes. The web client is a Next.js app you build and serve from your own machine; it is the only part
of the project with a server side at all, and it stores neither keys nor messages. Point it at a
model server on your own hardware and no request leaves your network. The model catalog can be
self-hosted too: give the web build a `NEXT_PUBLIC_BACKEND_URL` of your own, or the Android build
a `-PORIVEO_METADATA_BASE_URL`, and nothing in the app reaches out past your network at all.

</details>

<details>
<summary><b>How is this different from the app on the App Store?</b></summary>

<br>

The store apps are Oriveo, a proprietary product that adds an account, cross-device cloud sync,
usage insights, and models Oriveo pays for. Community Edition is the same three clients without any
of that: no account, no sync service, no billing, and nothing reporting back to us. See
[Community Edition and Oriveo](#community-edition-and-oriveo) for the full comparison.

</details>

<details>
<summary><b>Is there a macOS client?</b></summary>

<br>

A native macOS client is in development and will be released in the coming months; `macos/` is
where it will land. Until then the web client makes a good desktop app in any browser, and the iOS
build runs on an Apple silicon Mac straight from Xcode. The Swift package that speaks to the
providers already declares macOS 15 as a supported platform, so the wire layer a Mac client needs
is written and under test today. See [macos/README.md](macos/README.md).

</details>

<details>
<summary><b>Which languages is the interface available in?</b></summary>

<br>

Sixteen: Arabic, German, English, Spanish, French, Hindi, Indonesian, Japanese, Korean, Brazilian
Portuguese, Russian, Thai, Turkish, Vietnamese, Simplified Chinese, and Traditional Chinese. Arabic
gets a full right-to-left layout.

</details>

## Repository layout

```
ios/           iOS client (SwiftUI)
android/       Android client (Jetpack Compose)
web/           Web client (Next.js)
macos/         macOS client — in development, arriving in the coming months
shared/        Cross-client contracts, recorded fixtures, and the Swift wire kernel
readme_i18n/   These READMEs in fifteen more languages
docs/assets/   Images used by the READMEs
```

## Contributing

Bug reports and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers how to build
each client and what a good pull request looks like; [COMMUNITY.md](COMMUNITY.md) describes what
this edition is for, and the few kinds of change that will not be accepted no matter how well
written.

Found a security problem? Please do not open a public issue — [SECURITY.md](SECURITY.md) explains
how to report it privately, and what this project does and does not treat as a vulnerability.
Everyone taking part is expected to follow the [code of conduct](CODE_OF_CONDUCT.md).

## License

[AGPL-3.0-or-later](LICENSE). Contributions are accepted under the same license.

Provider names and logos belong to their respective owners and appear here only to identify the
services this client can be pointed at. They are not covered by this repository's license, and
their presence is not an endorsement by anyone. The fonts and libraries the clients bundle, and
the terms they come under, are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
