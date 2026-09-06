<div align="center">

# macOS용 Oriveo

**네이티브 Mac 클라이언트, 개발 중.**

<sub>

<a href="../../macos/README.md">English</a> ·
<a href="../ar/macos.md">العربية</a> ·
<a href="../de/macos.md">Deutsch</a> ·
<a href="../es/macos.md">Español</a> ·
<a href="../fr/macos.md">Français</a> ·
<a href="../hi/macos.md">हिन्दी</a> ·
<a href="../id/macos.md">Indonesia</a> ·
<a href="../ja/macos.md">日本語</a> ·
**한국어** ·
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

네이티브 macOS 클라이언트는 개발 중이고 앞으로 몇 달 안에 출시됩니다. 아직 이 저장소에는 없습니다 —
다른 세 클라이언트 옆, 바로 이 디렉터리가 그 자리입니다.

크기만 늘린 휴대폰 앱이 아니라 Mac 애플리케이션으로 만들고 있습니다. 진짜 창, 이미 손이 기억하는
키보드 단축키, 그리고 다른 클라이언트와 같은 로컬 우선 저장. 다른 클라이언트처럼 BYOK이고, 같은 공유
공급자 계약을 지키므로 한 번 고친 프로토콜 특이 동작은 어디서나 고쳐집니다.

## Mac에서 이미 돌아가는 것

- **웹 클라이언트**. 아무 브라우저에서나 충분히 좋은 데스크톱 앱이 됩니다:

  ```bash
  cd web
  npm install
  npm run dev:app        # http://localhost:3001
  ```

  [web/README.md](web.md)를 보세요.

- **iOS 빌드**. Apple silicon Mac에서 돌아갑니다. `ios/Oriveo/Oriveo.xcodeproj`를 열고
  *My Mac (Designed for iPad)* destination을 골라 실행하세요. [ios/README.md](ios.md)를 보세요.

## 이미 작성되어 있는 것

Mac 클라이언트에 필요한 wire 계층은 이미 있고 오늘도 테스트되고 있습니다.
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — *이 모델, 이 기능*을 HTTP 요청으로
바꾸는 Swift 패키지이자 iOS 앱이 링크하는 바로 그 패키지 — 는
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift)에서 iOS 18과 나란히 macOS 15를
선언합니다:

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

그 스위트는 시뮬레이터 없이 macOS에서 돌아갑니다:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

[루트 README](README.md) · [공유 계약](shared.md)
