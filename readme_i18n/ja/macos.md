<div align="center">

# macOS 版 Oriveo

**ネイティブな Mac クライアント、開発中。**

<sub>

<a href="../../macos/README.md">English</a> ·
<a href="../ar/macos.md">العربية</a> ·
<a href="../de/macos.md">Deutsch</a> ·
<a href="../es/macos.md">Español</a> ·
<a href="../fr/macos.md">Français</a> ·
<a href="../hi/macos.md">हिन्दी</a> ·
<a href="../id/macos.md">Indonesia</a> ·
**日本語** ·
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

ネイティブな macOS クライアントは開発中で、数か月のうちにリリースされます。まだこのリポジトリには
入っていません。このディレクトリが、ほかの 3 つのクライアントと並んでその置き場所になります。

作っているのは、スマートフォンのアプリを引き伸ばしたものではなく Mac のアプリケーションです。本物の
ウインドウ、すでに指が覚えているキーボードショートカット、そしてほかのクライアントと同じローカル
ファーストのストレージ。ほかと同じく BYOK で、同じ共有プロバイダーコントラクトを満たすので、一度
直したプロトコルの癖はどこでも直っています。

## すでに Mac で動くもの

- **Web クライアント**。どのブラウザでも申し分のないデスクトップアプリになります。

  ```bash
  cd web
  npm install
  npm run dev:app        # http://localhost:3001
  ```

  [web.md](web.md) を参照してください。

- **iOS 版のビルド**。Apple シリコンの Mac で動きます。`ios/Oriveo/Oriveo.xcodeproj` を開き、
  *My Mac (Designed for iPad)* の destination を選んで実行してください。[ios.md](ios.md) を参照して
  ください。

## すでに書かれているもの

Mac クライアントに必要な通信層はすでにあり、今日もテストされています。
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — *このモデルの、この機能*を HTTP
リクエストに変換する Swift パッケージであり、iOS アプリがリンクしているのと同じパッケージです — は、
その [`Package.swift`](../../shared/OriveoProviderKit/Package.swift) で iOS 18 と並べて macOS 15 を
宣言しています。

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

そのテストスイートは、シミュレーターを一切使わずに macOS 上で動きます。

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

[ルート README](README.md) · [共有コントラクト](shared.md)
