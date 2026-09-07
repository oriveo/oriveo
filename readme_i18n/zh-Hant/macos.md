<div align="center">

# Oriveo for macOS

**一個原生 Mac 用戶端，正在開發中。**

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
<a href="../tr/macos.md">Türkçe</a> ·
<a href="../vi/macos.md">Tiếng Việt</a> ·
<a href="../zh-Hans/macos.md">简体中文</a> ·
**繁體中文**

</sub>

</div>

---

一個原生 macOS 用戶端正在開發中，會在未來幾個月推出。它還不在這個儲存庫裡 —— 這個目錄就是它將來
落腳的地方，和另外三個用戶端並排。

它是當成一個 Mac 應用程式在做，而不是把手機應用放大：真正的視窗、你早就形成肌肉記憶的那些鍵盤快速鍵，
以及和其他用戶端一樣的本機優先儲存。和它們一樣，它也是自備金鑰的，並且遵守同一套共用的供應商契約，
所以一個協定怪癖修一次，就等於處處都修好了。

## 在 Mac 上已經跑得起來的東西

- **網頁用戶端**，它在任何瀏覽器裡都是個相當好用的桌面應用。請見
  [web.md — 快速開始](web.md#快速開始)。

- **iOS 版建置**，跑在 Apple 晶片的 Mac 上。開啟 `ios/Oriveo/Oriveo.xcodeproj`，選擇
  *My Mac (Designed for iPad)* 這個執行目標，然後執行。請見 [ios.md](ios.md)。

## 已經寫好的部分

Mac 用戶端所需的通訊層今天已經存在，而且在測試之中。
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) —— 那個把*這個模型、這項能力*變成一個
HTTP 請求的 Swift 套件，也就是 iOS 應用所連結的同一個套件 —— 在它的
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift) 裡把 macOS 15 和 iOS 18 一起宣告了
出來：

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

它那套測試在 macOS 上直接跑，完全不牽涉模擬器：

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

## 授權條款

[AGPL-3.0-or-later](../../LICENSE)。

[根 README](README.md) · [共用契約](shared.md)
