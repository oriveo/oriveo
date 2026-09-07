<div align="center">

# macOS के लिए Oriveo

**एक नेटिव Mac क्लाइंट, जो बन रहा है।**

<sub>

<a href="../../macos/README.md">English</a> ·
<a href="../ar/macos.md">العربية</a> ·
<a href="../de/macos.md">Deutsch</a> ·
<a href="../es/macos.md">Español</a> ·
<a href="../fr/macos.md">Français</a> ·
**हिन्दी** ·
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

एक नेटिव macOS क्लाइंट बन रहा है और अगले कुछ महीनों में रिलीज़ होगा। वह अभी इस रिपॉज़िटरी में नहीं है —
यह डायरेक्टरी वही जगह है जहाँ वह बाक़ी तीन क्लाइंट के साथ आएगा।

उसे बड़े किए हुए फ़ोन ऐप की तरह नहीं, बल्कि एक Mac एप्लिकेशन की तरह बनाया जा रहा है: असली विंडो, वही
कीबोर्ड शॉर्टकट जिनकी आपको पहले से आदत है, और वही लोकल-फ़र्स्ट स्टोरेज जो बाक़ी क्लाइंट इस्तेमाल करते
हैं। उनकी तरह वह भी अपनी-खुद-की-key वाला है, और वही साझा प्रोवाइडर कॉन्ट्रैक्ट निभाता है, इसलिए
प्रोटोकॉल की कोई ख़ास आदत एक बार ठीक हो जाए तो हर जगह ठीक हो जाती है।

## Mac पर अभी क्या चलता है

- **वेब क्लाइंट**, जो किसी भी ब्राउज़र में एक बिलकुल ठीक डेस्कटॉप ऐप बन जाता है।
  [web.md — जल्दी शुरू करें](web.md#जल्दी-शुरू-करें) देखें।

- **iOS बिल्ड**, Apple silicon वाले Mac पर। `ios/Oriveo/Oriveo.xcodeproj` खोलें,
  *My Mac (Designed for iPad)* destination चुनें, और चलाएँ। [ios.md](ios.md) देखें।

## अभी क्या लिखा जा चुका है

Mac क्लाइंट को जिस wire लेयर की ज़रूरत है, वह मौजूद है और आज टेस्ट के अंदर है।
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — वह Swift package जो *इस मॉडल, इस
capability* को एक HTTP रिक्वेस्ट में बदलता है, और वही package जिससे iOS ऐप लिंक करता है — अपनी
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift) में iOS 18 के साथ-साथ macOS 15 भी
घोषित करता है:

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

उसकी सुइट किसी simulator के बिना, macOS पर ही चलती है:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

वेब ऐप एक typed desktop-host interface भी रखता है,
[`web/packages/ipc-contract`](../../web/packages/ipc-contract/), जिससे कोई नेटिव shell बँध सकता है;
इस रिपॉज़िटरी में कुछ भी उसे लागू नहीं करता।

## लाइसेंस

[AGPL-3.0-or-later](../../LICENSE)।

[मुख्य README](README.md) · [साझा कॉन्ट्रैक्ट](shared.md)
