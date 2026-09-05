# iOS

Native Oriveo iOS client for local BYOK use.

## Scope

- Local chat with user-owned providers (OpenAI-compatible, Anthropic, Gemini, Relay, local engines, and similar)
- Local notes, folders, and skills
- Local message/session cost estimates from on-device data
- Public model catalog for unified model behavior (capability recipes and pricing)
- No account required; all data stays on the device

## Layout

```
ios/
  README.md
  Oriveo/                 # Xcode project root
shared/OriveoProviderKit  # local Swift package (../../shared/OriveoProviderKit)
```

## Bring your own key

Configure a provider API key or Relay/local endpoint on first send.

## Run on your iPhone

You need a Mac with Xcode, an Apple ID, and a device on iOS 18 or later. A free Personal Team is
enough: this app has no Push, Associated Domains, or other paid capabilities.

The project is built and tested with Xcode 26. Its project file uses `objectVersion = 77` and
file-system synchronized groups, so an older Xcode may refuse to open it; if yours does, update
Xcode rather than editing the project format.

1. Open `ios/Oriveo/Oriveo.xcodeproj`.
2. Select the `Oriveo` scheme.
3. In Signing & Capabilities, choose **your** Team. Leave Automatically manage signing on.
4. If Xcode cannot register `ai.oriveo.community`, change the bundle identifier to one your team owns.
5. Connect the iPhone, enable Developer Mode, and trust the computer.
6. Product → Run.

The first launch asks for an API key. There is no account.

To build for Simulator only, pick any iPhone simulator and Run. Package dependencies resolve from the committed `Package.resolved`.
