<div align="center">

# Oriveo สำหรับ macOS

**ไคลเอนต์ Mac แบบเนทีฟ อยู่ระหว่างการพัฒนา**

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
**ไทย** ·
<a href="../tr/macos.md">Türkçe</a> ·
<a href="../vi/macos.md">Tiếng Việt</a> ·
<a href="../zh-Hans/macos.md">简体中文</a> ·
<a href="../zh-Hant/macos.md">繁體中文</a>

</sub>

</div>

---

ไคลเอนต์ macOS แบบเนทีฟอยู่ระหว่างการพัฒนา และจะออกในอีกไม่กี่เดือน
มันยังไม่อยู่ในที่เก็บโค้ดนี้ — ไดเรกทอรีนี้คือที่ที่มันจะมาลง ข้าง ๆ ไคลเอนต์อีกสามตัว

มันถูกสร้างขึ้นเป็นแอปพลิเคชันของ Mac ไม่ใช่แอปโทรศัพท์ที่ขยายขนาด ได้แก่ หน้าต่างจริง ๆ
คีย์ลัดที่มือคุณจำได้อยู่แล้ว และการจัดเก็บแบบเก็บในเครื่องเป็นหลักชุดเดียวกับที่ไคลเอนต์ตัวอื่นใช้
เช่นเดียวกับพวกมัน มันใช้คีย์ของคุณเอง และทำตามข้อกำหนดร่วมของผู้ให้บริการชุดเดียวกัน
พฤติกรรมประหลาดของโปรโตคอลที่แก้ครั้งเดียวจึงถือว่าแก้ครบทุกที่

## อะไรที่รันบน Mac ได้อยู่แล้ว

- **ไคลเอนต์เว็บ** ซึ่งใช้เป็นแอปเดสก์ท็อปในเบราว์เซอร์ใดก็ได้อย่างดีเยี่ยม

  ```bash
  cd web
  npm install
  npm run dev:app        # http://localhost:3001
  ```

  ดู [web/README.md](web.md)

- **บิลด์ iOS** บน Mac ที่ใช้ Apple silicon เปิด `ios/Oriveo/Oriveo.xcodeproj` เลือกปลายทาง
  *My Mac (Designed for iPad)* แล้วกด Run ดู [ios/README.md](ios.md)

## อะไรที่เขียนไว้แล้ว

ชั้นสื่อสารที่ไคลเอนต์บน Mac ต้องใช้มีอยู่แล้วและอยู่ในการทดสอบวันนี้
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — Swift package ที่แปลง *โมเดลนี้
ความสามารถนี้* ให้เป็นคำขอ HTTP และเป็น package เดียวกับที่แอป iOS ลิงก์อยู่ — ประกาศ macOS 15
ไว้ข้าง iOS 18 ใน [`Package.swift`](../../shared/OriveoProviderKit/Package.swift) ของมัน:

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

ชุดทดสอบของมันรันบน macOS ได้โดยไม่ต้องพึ่งซิมูเลเตอร์เลย

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

[README หลัก](README.md) · [ข้อกำหนดร่วม](shared.md)
