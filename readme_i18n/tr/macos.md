<div align="center">

# macOS için Oriveo

**Geliştirme aşamasında, yerel bir Mac istemcisi.**

<sub>

<a href="../../macos/README.md">English</a> ·
<a href="../ar/macos.md">العربية</a> ·
<a href="../de/macos.md">Deutsch</a> ·
<a href="../es/macos.md">Español</a> ·
<a href="../fr/macos.md">Français</a> ·
<a href="../hi/macos.md">हिन्दी</a> ·
<a href="../id/macos.md">Indonesia</a> ·
<a href="../ja/macos.md">日本語</a> ·
<a href="../ko/macos.md">한국어</a> ·
<a href="../pt-BR/macos.md">Português</a> ·
<a href="../ru/macos.md">Русский</a> ·
<a href="../th/macos.md">ไทย</a> ·
**Türkçe** ·
<a href="../vi/macos.md">Tiếng Việt</a> ·
<a href="../zh-Hans/macos.md">简体中文</a> ·
<a href="../zh-Hant/macos.md">繁體中文</a>

</sub>

</div>

---

Yerel bir macOS istemcisi geliştirme aşamasında ve önümüzdeki aylarda yayınlanacak. Henüz bu depoda
değil — bu dizin, diğer üç istemcinin yanında ineceği yer.

Büyütülmüş bir telefon uygulaması değil, bir Mac uygulaması olarak yapılıyor: gerçek pencereler,
kas hafızanızda zaten olan klavye kısayolları ve diğer istemcilerin kullandığı aynı local-first
depolama. Onlar gibi o da kendi anahtarınızı getirdiğiniz bir istemci ve aynı ortak sağlayıcı
sözleşmelerini karşılıyor; yani bir kez düzeltilen bir protokol tuhaflığı her yerde düzeltilmiş olur.

## Bir Mac'te hâlihazırda çalışanlar

- **Web istemcisi**, herhangi bir tarayıcıda gayet iyi bir masaüstü uygulaması olur. Bkz.
  [web.md — Hızlı başlangıç](web.md#hızlı-başlangıç).

- **iOS derlemesi**, bir Apple silicon Mac'te. `ios/Oriveo/Oriveo.xcodeproj` dosyasını açın,
  *My Mac (Designed for iPad)* hedefini seçin ve çalıştırın. Bkz. [ios.md](ios.md).

## Hâlihazırda yazılmış olanlar

Bir Mac istemcisinin ihtiyaç duyduğu protokol katmanı bugün var ve test altında.
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — *bu model, bu yetenek* ikilisini bir
HTTP isteğine çeviren Swift paketi ve iOS uygulamasının bağlandığı aynı paket — kendi
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift) dosyasında macOS 15'i iOS 18'in
yanında bildirir:

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

Test paketi, hiçbir simülatör devreye girmeden macOS üzerinde çalışır:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

## Lisans

[AGPL-3.0-or-later](../../LICENSE).

[Kök README](README.md) · [Ortak sözleşmeler](shared.md)
