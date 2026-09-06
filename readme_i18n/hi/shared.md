<div align="center">

# साझा कॉन्ट्रैक्ट

**मॉडल प्रोवाइडर से कैसे बात करनी है, इसकी एक ही परिभाषा — जिसे तीनों क्लाइंट टेस्ट करते हैं।**

<a href="../../LICENSE"><img alt="लाइसेंस AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="Swift 6.1 package" src="https://img.shields.io/badge/Swift-6.1-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="JSON कॉन्ट्रैक्ट" src="https://img.shields.io/badge/contracts-JSON-A78BFA?style=flat-square&labelColor=black">

<sub>

<a href="../../shared/README.md">English</a> ·
<a href="../ar/shared.md">العربية</a> ·
<a href="../de/shared.md">Deutsch</a> ·
<a href="../es/shared.md">Español</a> ·
<a href="../fr/shared.md">Français</a> ·
**हिन्दी** ·
<a href="../id/shared.md">Indonesia</a> ·
<a href="../ja/shared.md">日本語</a> ·
<a href="../ko/shared.md">한국어</a> ·
<a href="../pt-BR/shared.md">Português</a> ·
<a href="../ru/shared.md">Русский</a> ·
<a href="../th/shared.md">ไทย</a> ·
<a href="../tr/shared.md">Türkçe</a> ·
<a href="../vi/shared.md">Tiếng Việt</a> ·
<a href="../zh-Hans/shared.md">简体中文</a> ·
<a href="../zh-Hant/shared.md">繁體中文</a>

</sub>

</div>

---

तीन क्लाइंट अगर "प्रोवाइडर को कॉल करो" को अलग-अलग लागू करें तो वे एक-दूसरे से बहक जाएँगे। और चुपचाप
बहकेंगे — उसी दिशा में जिसे किसी ने आख़िरी बार टेस्ट किया था — और यह बहकाव आख़िर में ऐसे बग के रूप में
सामने आएगा जो एक प्लैटफ़ॉर्म पर दोहराया जा सके और बाक़ी पर नहीं।

`shared/` इसी का जवाब है: व्यवहार एक ही बार डेटा के रूप में लिख दिया जाता है, और हर क्लाइंट की टेस्ट
suite उन्हीं फ़ाइलों के विरुद्ध जाँच करती है। जो ख़ास आदत उसी डेटा में बैठी है, वह एक बार ठीक होती है।
जो ख़ास आदत किसी parser में बैठी है, उसे तीनों suites एक साथ पकड़ लेती हैं, बजाय इसके कि वह दो
प्लैटफ़ॉर्म पर ship हो जाए और तीसरे को तोड़ दे।

```mermaid
flowchart LR
    subgraph contracts ["shared/"]
        direction TB
        recipes["capabilityrecipe<br/>रिक्वेस्ट कैसी बनेगी"]
        models["model-contracts<br/>क्लाइंट क्या कर सकता है"]
        fixtures["test-fixtures<br/>रिकॉर्ड किया गया upstream ट्रैफ़िक"]
        kit["OriveoProviderKit<br/>Swift wire kernel"]
    end

    iosT["iOS suites"]
    andT["Android suites"]
    webT["वेब suites"]

    recipes & models & fixtures --> iosT & andT & webT
    kit --> iosT
```

## capabilityrecipe

Recipe रजिस्ट्री। किसी दिए गए प्रोवाइडर, transport और capability के लिए — वेब सर्च, reasoning effort,
इमेज जनरेशन — यह ठीक-ठीक बताती है कि जाने वाली रिक्वेस्ट में कौन-से JSON pointer लिखने हैं, और जवाब को
वापस कैसे पढ़ना है।

यही वह चीज़ है जिससे आज रिलीज़ हुआ मॉडल बिना क्लाइंट अपडेट के काम करता है, और यही वजह है कि कोई भी
क्लाइंट मॉडल के नाम से capability नहीं भाँपता। `capability_runtime.v1.json` में recipes ख़ुद रहती हैं;
`capability_result_definitions.v1.json` और `capability_custom_controls.v2.json` तय करती हैं कि नतीजों
और उपयोगकर्ता को दिखने वाले कंट्रोल की व्याख्या कैसे हो।

हर recipe एक `executionKind` घोषित करती है — `request_overlay`, `server_tool`, `client_tool_loop`,
`endpoint_route`, `model_route`, `external_connector`, `unavailable` — और हर क्लाइंट का compiler recipe
लागू करने से पहले जाँचता है कि वह प्रोवाइडर, capability और transport से मेल खाती है, और न मिलने पर
नामज़द वजह के साथ अस्वीकार कर देता है, बजाय ऐसी रिक्वेस्ट भेजने के जिसे किसी ने देखा ही न हो। यह सूची
एक बंद समुच्चय है: इनके अलावा कुछ और नाम लेने वाली recipe भाँपी नहीं जाती, अस्वीकार कर दी जाती है।

## model-contracts

JSON fixtures जो क्लाइंट-दर-क्लाइंट व्यवहार को बाँधती हैं: किसी प्रोवाइडर और capability के लिए
रिक्वेस्ट कैसी दिखनी चाहिए, generation पैरामीटर कैसे तय होते हैं और override किस क्रम में परत दर परत
चढ़ते हैं, कोई क्लाइंट किन capability states को दिखा सकता है, और मॉडल कैटलॉग तथा उसके evidence का
उपभोग कैसे होता है।

हर क्लाइंट के टेस्ट इन्हें सीधे लोड करते हैं, इसलिए यहाँ हुआ बदलाव एक ही बार में तीनों क्लाइंट का
बदलाव है।

## test-fixtures

Golden टेस्ट डेटा: रिकॉर्ड किया गया upstream tool-call ट्रैफ़िक, relay routing, फ़ॉर्म validation,
लोकल-पते का वर्गीकरण, कैटलॉग और portable-config के परिदृश्य, model-facts और capability-evidence के
snapshot, और local-engine परिदृश्य।

`recorded/` के नीचे की `.sse` फ़ाइलें **असली, कैप्चर किया गया upstream ट्रैफ़िक** हैं, जैसी आईं वैसी ही
बाइट-दर-बाइट रखी गईं — सिर्फ़ response हेडर हटाए गए, और उनके body में कभी कोई key नहीं थी। बाक़ी हाथ से
लिखे fixtures हैं जो किसी एक ख़ास parse path को pin करते हैं। यह फ़र्क़
मायने रखता है: हाथ से लिखा mock वह encode करता है जो आपको लगता था कि प्रोवाइडर करता है, जबकि रिकॉर्डिंग
वह encode करती है जो उसने वाक़ई किया — उस मंगलवार को भेजा गया वह टूटा-फूटा chunk भी शामिल। जब प्रोवाइडर
प्रोटोकॉल के किसी फ़िक्स को टेस्ट चाहिए, तो रिकॉर्डिंग को तरजीह दें।

किसी fixture का `$comment`, या उसके बग़ल में रखा `expected.json` manifest, बताता है कि उसके आस-पास की
entries किस चीज़ को pin करती हैं। कोई नया केस जोड़ने से पहले उसे पढ़ लें।

## OriveoProviderKit

एक Swift package जिसमें प्रोवाइडर wire-protocol का kernel है: SSE लाइन असेंबली, OpenAI-कम्पैटिबल chunk
parsing, Responses / Anthropic Messages / Gemini प्रोटोकॉल के लिए event-आधारित असेंबली, transport से
निरपेक्ष request निर्माण, recipe compilation और उसके execution guards, tool-name encoding, credential
redaction, upstream error classification, thinking-tag parsing, streaming JSON path extraction, एक
स्पष्ट `URLSession` redirect नीति, और हर vendor की ख़ास आदतों वाली profiles।

इसका दायरा जानबूझकर तंग खींचा गया है। **भीतर:** सिर्फ़ Foundation पर टिकी wire जानकारी। **बाहर:** ऐप
मॉडल, UI, डेटाबेस, telemetry, स्थानीयकरण। यह package standard library और Foundation के अलावा किसी चीज़
पर निर्भर नहीं है, और Apple का हर क्लाइंट इसके इर्द-गिर्द एक पतली binding रखता है, ताकि wire व्यवहार का
ठीक एक ही implementation रहे।

यह Apple प्लैटफ़ॉर्म के लिए पूरा request-और-streaming रास्ता लागू करता है। iOS ऐप फ़िलहाल इसका एक
हिस्सा ही लिंक करता है — stream assemblers, wire profiles, tool-name codec और error classifiers — और
अपने request builders ख़ुद रखता है; बन रहा macOS क्लाइंट दूसरा उपभोक्ता है, और इसीलिए recipe compiler
तथा transport से निरपेक्ष request builder किसी एक ऐप के भीतर नहीं, बल्कि यहाँ रहते हैं। नीचे दी सुइट
उन हिस्सों को कवर करती है जो हर उपभोक्ता साझा करता है: SSE splitting, OpenAI-कम्पैटिबल असेंबली,
tool-name codec और redirect नीति।

```bash
cd shared/OriveoProviderKit && swift build && swift test
```

- प्लैटफ़ॉर्म: iOS 18+, macOS 15+ · `swift-tools-version: 6.1`
- `ProviderWireProfile` उन बची-खुची vendor-विशिष्ट आदतों को संभालता है जो एक ही OpenAI-कम्पैटिबल
  assembler को अब भी चाहिए — reasoning टेक्स्ट कहाँ आता है, cached-token की गिनती कहाँ रहती है, और
  prompt token में cache hit पहले से शामिल हैं या नहीं। यह बताता है कि *बाइट्स कैसे आती हैं*, कभी यह
  नहीं कि *कोई मॉडल क्या कर सकता है*; वह काम recipes का है।

## इन फ़ाइलों पर काम करना

यहाँ हुआ बदलाव हर क्लाइंट का बदलाव है। जिस फ़ाइल को आपने छुआ है उसे पढ़ने वाले हर क्लाइंट की contract
suites चलाएँ, सिर्फ़ उसी की नहीं जिसमें आप इस वक़्त काम कर रहे हैं:

रिपॉज़िटरी की जड़ से:

```bash
(cd web && npm run test:run)
(cd shared/OriveoProviderKit && swift test)
# plus the iOS and Android suites — see their READMEs
```

iOS की suites इस डायरेक्टरी को टेस्ट फ़ाइल से ऊपर चढ़ते हुए `shared/` खोजकर पाती हैं; Android की suites
Gradle मॉड्यूल से `../../shared` resolve करती हैं; और वेब suites इसे workspace के सापेक्ष resolve करती
हैं। इसलिए इन सबको रिपॉज़िटरी का पूरा checkout चाहिए।

## लाइसेंस

[AGPL-3.0-or-later](../../LICENSE)।
