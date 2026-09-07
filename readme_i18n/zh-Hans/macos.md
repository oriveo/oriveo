<div align="center">

# Oriveo for macOS

**一个原生 Mac 客户端，正在开发中。**

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
**简体中文** ·
<a href="../zh-Hant/macos.md">繁體中文</a>

</sub>

</div>

---

一个原生 macOS 客户端正在开发中，会在未来几个月发布。它还不在本仓库里 —— 这个目录就是它将来落脚的
地方，和另外三个客户端并排。

它是按一个 Mac 应用来做的，而不是把手机应用放大：真正的窗口、你早已形成肌肉记忆的那些键盘快捷键，
以及和其他客户端一样的本地优先存储。和它们一样，它也是自带 Key 的，并且遵守同一套共享的供应商契约，
所以一个协议怪癖修一次，就等于处处都修好了。

## 在 Mac 上已经能跑什么

- **Web 客户端**，它在任意浏览器里都是个相当好用的桌面应用。见
  [web.md — 快速开始](web.md#快速开始)。

- **iOS 构建**，跑在 Apple 芯片的 Mac 上。打开 `ios/Oriveo/Oriveo.xcodeproj`，选择
  *My Mac (Designed for iPad)* 这个运行目标，然后运行。见 [ios.md](ios.md)。

## 已经写好的部分

Mac 客户端所需的通信层今天已经存在，而且在测试之中。
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) —— 那个把*这个模型、这项能力*翻译成
一个 HTTP 请求的 Swift 包，也就是 iOS App 链接的同一个包 —— 在它的
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift) 里把 macOS 15 和 iOS 18 一起声明了
出来：

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

它那套测试在 macOS 上直接跑，不牵涉任何模拟器：

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

## 许可证

[AGPL-3.0-or-later](../../LICENSE)。

[根 README](README.md) · [共享契约](shared.md)
