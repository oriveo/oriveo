<div align="center">

# Oriveo cho macOS

**Một client Mac native, đang được phát triển.**

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
**Tiếng Việt** ·
<a href="../zh-Hans/macos.md">简体中文</a> ·
<a href="../zh-Hant/macos.md">繁體中文</a>

</sub>

</div>

---

Một client macOS native đang được phát triển và sẽ ra mắt trong vài tháng tới. Nó chưa nằm trong kho
mã này — thư mục này là nơi nó sẽ nằm, cạnh ba client kia.

Nó được dựng như một ứng dụng Mac chứ không phải một ứng dụng điện thoại phóng to: cửa sổ thật, những
tổ hợp bàn phím mà tay bạn đã quen, và cùng kiểu lưu trữ ưu tiên cục bộ mà các client khác dùng.
Giống chúng, nó cũng dùng khóa của chính bạn, và nó thỏa mãn đúng những contract nhà cung cấp dùng
chung, nên một điểm kỳ quặc của giao thức đã sửa một lần là sửa ở mọi nơi.

## Những gì đã chạy được trên máy Mac

- **Client web**, dùng như một ứng dụng desktop trên trình duyệt bất kỳ vẫn rất tốt:

  ```bash
  cd web
  npm install
  npm run dev:app        # http://localhost:3001
  ```

  Xem [web/README.md](web.md).

- **Bản dựng iOS**, trên một máy Mac dùng Apple silicon. Mở `ios/Oriveo/Oriveo.xcodeproj`, chọn đích
  *My Mac (Designed for iPad)* rồi nhấn Run. Xem [ios/README.md](ios.md).

## Những gì đã được viết

Lớp giao thức mà một client cho Mac cần đã tồn tại và đang được kiểm thử ngay hôm nay.
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — package Swift biến *mô hình này, khả
năng này* thành một yêu cầu HTTP, cũng chính là package mà ứng dụng iOS liên kết tới — khai báo
macOS 15 bên cạnh iOS 18 trong
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift) của nó:

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

Bộ test của nó chạy trên macOS mà không cần tới simulator nào:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

[README gốc](README.md) · [Contract dùng chung](shared.md)
