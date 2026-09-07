<div align="center">

# Oriveo untuk macOS

**Klien Mac native, sedang dikembangkan.**

<sub>

<a href="../../macos/README.md">English</a> ·
<a href="../ar/macos.md">العربية</a> ·
<a href="../de/macos.md">Deutsch</a> ·
<a href="../es/macos.md">Español</a> ·
<a href="../fr/macos.md">Français</a> ·
<a href="../hi/macos.md">हिन्दी</a> ·
**Indonesia** ·
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

Klien macOS native sedang dikembangkan dan akan dirilis dalam beberapa bulan ke depan. Ia belum ada
di repositori ini — direktori inilah tempatnya nanti, berdampingan dengan tiga klien lainnya.

Ia dibangun sebagai aplikasi Mac, bukan aplikasi ponsel yang diubah ukurannya: jendela sungguhan,
shortcut papan ketik yang sudah menjadi refleks Anda, dan penyimpanan local-first yang sama seperti
yang dipakai klien lain. Seperti mereka, ia bring-your-own-key, dan ia memenuhi kontrak provider
bersama yang sama, jadi keanehan protokol yang diperbaiki sekali diperbaiki di mana-mana.

## Apa yang sudah berjalan di Mac

- **Klien web**, yang menjadi aplikasi desktop yang benar-benar layak di browser mana pun. Lihat
  [web.md — Mulai cepat](web.md#mulai-cepat).

- **Build iOS**, di Mac dengan Apple silicon. Buka `ios/Oriveo/Oriveo.xcodeproj`, pilih destination
  *My Mac (Designed for iPad)*, lalu jalankan. Lihat [ios.md](ios.md).

## Apa yang sudah tertulis

Lapisan wire yang dibutuhkan sebuah klien Mac sudah ada dan sudah diuji hari ini.
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — package Swift yang mengubah *model
ini, capability ini* menjadi sebuah permintaan HTTP, dan package yang sama yang ditautkan aplikasi
iOS — mendeklarasikan macOS 15 berdampingan dengan iOS 18 di
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift):

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

Suite-nya berjalan di macOS tanpa simulator sama sekali:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

## Lisensi

[AGPL-3.0-or-later](../../LICENSE).

[README utama](README.md) · [Kontrak bersama](shared.md)
