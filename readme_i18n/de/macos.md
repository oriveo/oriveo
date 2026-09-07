<div align="center">

# Oriveo für macOS

**Ein nativer Mac-Client, in Entwicklung.**

<sub>

<a href="../../macos/README.md">English</a> ·
<a href="../ar/macos.md">العربية</a> ·
**Deutsch** ·
<a href="../es/macos.md">Español</a> ·
<a href="../fr/macos.md">Français</a> ·
<a href="../hi/macos.md">हिन्दी</a> ·
<a href="../id/macos.md">Indonesia</a> ·
<a href="../ja/macos.md">日本語</a> ·
<a href="../ko/macos.md">한국어</a> ·
<a href="../pt-BR/macos.md">Português</a> ·
<a href="../ru/macos.md">Русский</a> ·
<a href="../th/macos.md">ไทย</a> ·
<a href="../tr/macos.md">Türkçe</a> ·
<a href="../vi/macos.md">Tiếng Việt</a> ·
<a href="../zh-Hans/macos.md">简体中文</a> ·
<a href="../zh-Hant/macos.md">繁體中文</a>

</sub>

</div>

---

Ein nativer macOS-Client ist in Entwicklung und wird in den nächsten Monaten veröffentlicht. Er liegt
diesem Repository noch nicht bei – dieses Verzeichnis ist der Ort, an dem er landen wird, neben den
anderen drei Clients.

Er entsteht als Mac-Anwendung und nicht als vergrößerte Handy-App: echte Fenster, die Tastenkürzel,
für die du längst Muskelgedächtnis hast, und derselbe local-first-Speicher, den die anderen Clients
nutzen. Wie sie arbeitet er mit deinem eigenen Key, und er erfüllt dieselben gemeinsamen
Anbieter-Kontrakte, sodass eine einmal behobene Protokoll-Eigenheit überall behoben ist.

## Was auf einem Mac schon läuft

- **Der Web-Client**, der in jedem Browser eine völlig brauchbare Desktop-App abgibt. Siehe
  [web.md – Schnellstart](web.md#schnellstart).

- **Der iOS-Build**, auf einem Mac mit Apple Silicon. Öffne `ios/Oriveo/Oriveo.xcodeproj`, wähle das
  Ziel *My Mac (Designed for iPad)* und starte. Siehe [ios.md](ios.md).

## Was schon geschrieben ist

Die Wire-Schicht, die ein Mac-Client braucht, existiert und ist heute unter Test.
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) – das Swift-Paket, das *dieses Modell,
diese Funktion* in einen HTTP-Request verwandelt, und dasselbe Paket, gegen das die iOS-App linkt –
führt in seiner [`Package.swift`](../../shared/OriveoProviderKit/Package.swift) macOS 15 neben
iOS 18:

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

Seine Suite läuft auf macOS, ohne dass ein Simulator im Spiel ist:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

Die Web-App hält außerdem eine typisierte Schnittstelle für einen Desktop-Host bereit,
[`web/packages/ipc-contract`](../../web/packages/ipc-contract/), an die sich eine native Shell binden
kann; nichts in diesem Repository implementiert sie.

## Lizenz

[AGPL-3.0-or-later](../../LICENSE).

[README im Wurzelverzeichnis](README.md) · [Gemeinsame Kontrakte](shared.md)
