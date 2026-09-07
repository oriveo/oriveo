<div align="center">

# Oriveo لنظام macOS

**عميل Mac أصلي، قيد التطوير.**

<sub>

<a href="../../macos/README.md">English</a> ·
**العربية** ·
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
<a href="../zh-Hant/macos.md">繁體中文</a>

</sub>

</div>

---

هناك عميل macOS أصلي قيد التطوير وسيُطلَق في الأشهر القادمة. وهو ليس في هذا المستودع بعد — وهذا
المجلد هو المكان الذي سيحل فيه، إلى جانب العملاء الثلاثة الآخرين.

وهو يُبنى كتطبيق Mac لا كتطبيق هاتف مُكبَّر: نوافذ حقيقية، واختصارات لوحة المفاتيح التي حفظتها يداك
أصلا، والتخزين المحلي أولا نفسه الذي تستخدمه العملاء الأخرى. وهو مثلها يعمل بمفتاحك الخاص، ويستوفي
عقود المزودين المشتركة نفسها، فأي خصوصية في بروتوكول تُصلَح مرة واحدة تكون مُصلَحة في كل مكان.

## ما يعمل على Mac بالفعل

- **عميل الويب**، وهو يصلح تماما كتطبيق سطح مكتب في أي متصفح. انظر
  [web.md — البدء السريع](web.md#البدء-السريع).

- **بنية iOS**، على جهاز Mac بمعالج Apple silicon. افتح `ios/Oriveo/Oriveo.xcodeproj`، واختر الهدف
  *My Mac (Designed for iPad)*، ثم شغّل. انظر [ios.md](ios.md).

## ما كُتب بالفعل

طبقة الاتصال التي يحتاجها عميل Mac موجودة وتحت الاختبار اليوم. فحزمة
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — حزمة Swift التي تحوّل *هذا النموذج،
هذه القدرة* إلى طلب HTTP، وهي نفس الحزمة التي يرتبط بها تطبيق iOS — تعلن macOS 15 إلى جانب iOS 18 في
ملفها [`Package.swift`](../../shared/OriveoProviderKit/Package.swift):

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

وتعمل مجموعة اختباراتها على macOS دون أي محاكٍ:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

## الترخيص

[AGPL-3.0-or-later](../../LICENSE).

[README الجذر](README.md) · [العقود المشتركة](shared.md)
