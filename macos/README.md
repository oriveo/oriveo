<div align="center">

# Oriveo for macOS

**A native Mac client, in development.**

<sub>

**English** ·
<a href="../readme_i18n/ar/macos.md">العربية</a> ·
<a href="../readme_i18n/de/macos.md">Deutsch</a> ·
<a href="../readme_i18n/es/macos.md">Español</a> ·
<a href="../readme_i18n/fr/macos.md">Français</a> ·
<a href="../readme_i18n/hi/macos.md">हिन्दी</a> ·
<a href="../readme_i18n/id/macos.md">Indonesia</a> ·
<a href="../readme_i18n/ja/macos.md">日本語</a> ·
<a href="../readme_i18n/ko/macos.md">한국어</a> ·
<a href="../readme_i18n/pt-BR/macos.md">Português</a> ·
<a href="../readme_i18n/ru/macos.md">Русский</a> ·
<a href="../readme_i18n/th/macos.md">ไทย</a> ·
<a href="../readme_i18n/tr/macos.md">Türkçe</a> ·
<a href="../readme_i18n/vi/macos.md">Tiếng Việt</a> ·
<a href="../readme_i18n/zh-Hans/macos.md">简体中文</a> ·
<a href="../readme_i18n/zh-Hant/macos.md">繁體中文</a>

</sub>

</div>

---

A native macOS client is in development and will be released in the coming months. It is not in
this repository yet — this directory is where it will land, next to the other three clients.

It is being built as a Mac application rather than a resized phone app: real windows, the keyboard
shortcuts you already have muscle memory for, and the same local-first storage the other clients
use. Like them it is bring-your-own-key, and it meets the same shared provider contracts, so a
protocol quirk fixed once is fixed everywhere.

## What already runs on a Mac

- **The web client**, which makes a perfectly good desktop app in any browser. See
  [web/README.md — Quick start](../web/README.md#quick-start).

- **The iOS build**, on an Apple silicon Mac. Open `ios/Oriveo/Oriveo.xcodeproj`, choose the
  *My Mac (Designed for iPad)* destination, and run. See [ios/README.md](../ios/README.md).

## What is already written

The wire layer a Mac client needs exists and is under test today.
[`shared/OriveoProviderKit`](../shared/OriveoProviderKit/) — the Swift package that turns *this
model, this capability* into an HTTP request, and the same package the iOS app links against —
declares macOS 15 alongside iOS 18 in its
[`Package.swift`](../shared/OriveoProviderKit/Package.swift):

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

Its suite runs on macOS with no simulator involved:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

The web app also keeps a typed desktop-host interface,
[`web/packages/ipc-contract`](../web/packages/ipc-contract/), that a native shell can bind to;
nothing in this repository implements it.

## License

[AGPL-3.0-or-later](../LICENSE).

[Root README](../README.md) · [Shared contracts](../shared/README.md)
