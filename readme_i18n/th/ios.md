<div align="center">

# Oriveo สำหรับ iOS

**ไคลเอนต์แชท SwiftUI แบบเนทีฟ สำหรับโมเดล AI ที่คุณจ่ายเงินใช้อยู่แล้ว**

<a href="../../LICENSE"><img alt="สัญญาอนุญาต AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="iOS 18 ขึ้นไป" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white">
<img alt="สร้างด้วย Swift" src="https://img.shields.io/badge/Swift-6.1_package_·_Xcode_26-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="อินเทอร์เฟซ 16 ภาษา" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

<sub>

<a href="../../ios/README.md">English</a> ·
<a href="../ar/ios.md">العربية</a> ·
<a href="../de/ios.md">Deutsch</a> ·
<a href="../es/ios.md">Español</a> ·
<a href="../fr/ios.md">Français</a> ·
<a href="../hi/ios.md">हिन्दी</a> ·
<a href="../id/ios.md">Indonesia</a> ·
<a href="../ja/ios.md">日本語</a> ·
<a href="../ko/ios.md">한국어</a> ·
<a href="../pt-BR/ios.md">Português</a> ·
<a href="../ru/ios.md">Русский</a> ·
**ไทย** ·
<a href="../tr/ios.md">Türkçe</a> ·
<a href="../vi/ios.md">Tiếng Việt</a> ·
<a href="../zh-Hans/ios.md">简体中文</a> ·
<a href="../zh-Hant/ios.md">繁體中文</a>

</sub>

</div>

---

ไคลเอนต์ iOS ของ Oriveo คือแอปแชท AI แบบ bring-your-own-key คุณเพิ่ม API key
ที่คุณเป็นเจ้าของอยู่แล้ว แล้วแอปจะเรียกผู้ให้บริการแต่ละรายตรงจากเครื่องโทรศัพท์ บทสนทนา ข้อความ
โน้ต และโฟลเดอร์โน้ต อยู่ในฐานข้อมูล SQLite บนอุปกรณ์ ส่วนเนื้อไฟล์แนบเป็นไฟล์ที่วางอยู่ข้าง ๆ มัน
ขณะที่ทักษะ การตั้งค่า รายชื่อผู้ให้บริการ และโฟลเดอร์บทสนทนา เป็น JSON บนอุปกรณ์ ส่วน API key
เข้าไปอยู่ใน iOS Keychain

ไม่มีบัญชี Oriveo ไม่มีอะไรถูกอัปโหลด และไม่มีอะไรให้เข้าสู่ระบบ
มีผู้ให้บริการสองรายที่เปิดให้เข้าสู่ระบบด้วยแพ็กเกจสมาชิกที่คุณมีอยู่แล้วแทนการวางคีย์ลงไป —
ChatGPT และ Grok — และการเข้าสู่ระบบนั้นวิ่งไปหา OpenAI และ xAI ไม่ได้มาหาเรา

แอปนี้เป็นส่วนหนึ่งของ [Oriveo Community Edition](README.md) —
ไคลเอนต์สามตัวที่ใช้นิยามเดียวกันว่าจะคุยกับผู้ให้บริการโมเดลอย่างไร

## สถาปัตยกรรม

```mermaid
flowchart TB
    subgraph ui ["ชั้นนำเสนอ"]
        direction LR
        swiftui["SwiftUI<br/>NavigationStack · AppRoute"]
        uikit["transcript แบบ UIKit<br/>UICollectionView · ChatLayout"]
    end

    appstate["AppState · @Observable<br/>ChatManager · ProviderManager · NoteManager · SkillManager"]

    subgraph store ["บนอุปกรณ์"]
        direction LR
        grdb[("SQLite · GRDB")]
        keychain[["Keychain · API key"]]
        files[("รูปภาพ · ไฟล์")]
    end

    subgraph provider ["ชั้นผู้ให้บริการ"]
        direction LR
        services["ProviderService 15 ตัว<br/>relay ใช้ตัวของ OpenAI ซ้ำ"]
        transports["TransportRegistry<br/>12 กลยุทธ์"]
        kit["OriveoProviderKit<br/>SSE · ประกอบ chunk · ปกปิดคีย์"]
    end

    swiftui & uikit <--> appstate
    appstate <--> grdb & keychain & files
    appstate --> services
    services --> transports --> kit
    kit ==>|"คีย์ของคุณ"| up["ผู้ให้บริการโมเดล"]
```

มีสามเรื่องในแผนภาพนี้ที่ควรพูดให้ชัด

**transcript เป็น UIKit ส่วนที่เหลือเป็น SwiftUI** `ChatView` ฝัง
`ChatListViewControllerRepresentable` ครอบ `UICollectionView` ที่ขับเคลื่อนด้วย
[ChatLayout](https://github.com/ekazaev/ChatLayout) ส่วนอย่างอื่นทั้งหมด — การนำทาง การตั้งค่า
การตั้งค่าผู้ให้บริการ โน้ต ทักษะ — เป็น SwiftUI ที่แยกแบบนี้เพราะ transcript
ที่สตรีมมาด้วยความเร็วระดับ token ต้องการการควบคุมการวัดขนาดและการนำ cell กลับมาใช้ซ้ำในระดับ cell
ซึ่ง diffing ของ SwiftUI ให้ไม่ได้ ขอบเขตของการแยกนี้อธิบายไว้ใน
[`Features/Chat/ARCHITECTURE.md`](../../ios/Oriveo/Oriveo/Features/Chat/ARCHITECTURE.md)

**มีสามเส้นทางแยกกันที่อัปเดต transcript นั้น** และเป็นความตั้งใจ

| เส้นทาง | ส่งอะไร | ทำไม |
|---|---|---|
| `@Observable AppState` | การเปลี่ยนเชิงโครงสร้าง — ข้อความใหม่โผล่ขึ้นมา หรือสลับบทสนทนา | เป็นวิธีดั้งเดิมของ SwiftUI และต้นทุนต่ำสำหรับเหตุการณ์ที่เกิดไม่บ่อย |
| GRDB `ValueObservation` | สถานะถาวรที่อ่านกลับมาจาก SQLite | เป็นแหล่งความจริงเดียวหลังการเขียน และอยู่รอดข้ามการเปิดแอปใหม่ |
| Combine `PassthroughSubject` หนึ่งตัวต่อบทสนทนา | ข้อความและ delta ของการให้เหตุผลที่สตรีมเข้ามา | เลี่ยง diffing ของ SwiftUI ทั้งหมดที่ความเร็วระดับ token |

**การรองรับผู้ให้บริการเป็นสี่แกนอิสระ ไม่ใช่ enum เดียว** `ProviderKind` (16 กรณี คือผู้ให้บริการสิบห้าราย บวก relay) คือ
*ผู้ใช้ตั้งค่าอะไรไว้* `ProviderServiceProtocol` คือ *พื้นผิวสำหรับเรียกใช้* `TransportKind`
(12 กรณี) คือ *โปรโตคอล wire ที่ใช้พูดจริง ๆ* และถูกระบุ **รายโมเดล จากแคตตาล็อก**
สองโมเดลที่อยู่หลังคีย์เดียวกันจึงต่างกันได้ ส่วน `RelayKind` ดูแลปลายทางที่ผู้ใช้ใส่เอง
การแยกสิ่งเหล่านี้ออกจากกันคือเหตุผลที่โมเดลใหม่ใช้งานได้โดยไม่ต้องบิลด์ใหม่

### ข้อความหนึ่งถูกส่งอย่างไร

```mermaid
flowchart LR
    ui["ช่องพิมพ์"] --> build["ChatRequestSnapshot<br/>prompt · memory · โน้ต · ไฟล์แนบ"]
    build --> recipes["recipe ความสามารถ<br/>ระบุจากแคตตาล็อก"]
    recipes --> encode["encodeChatBody<br/>รอยต่อ wire เดียว"]
    encode ==>|"คีย์ของคุณ"| up(["ผู้ให้บริการโมเดล"])
    up ==> parse["TransportStrategy<br/>+ ตัวประกอบ OriveoProviderKit"]
    parse --> cells["transcript แบบสตรีม"]
```

`BaseAPIService.encodeChatBody` คือด่านสุดท้ายก่อนที่คำขอแบบเข้ากันได้กับ OpenAI จะกลายเป็นไบต์ —
สิบสองจากทั้งสิบหกกรณีผ่านจุดนี้ recipe ความสามารถ พารามิเตอร์การสร้าง
หรือฟิลด์ที่กำหนดเองจึงทดสอบได้ในที่เดียวแทนที่จะเป็นสิบสองที่ ส่วน OpenAI, Anthropic และ Gemini
พูดรูปแบบของตัวเองและ serialize ใน service ของตัวเอง แต่ละจุดเหล่านั้นมีชุดทดสอบรูปแบบคำขอของตัวเอง

## โมเดลได้รับอนุญาตให้ทำอะไรบ้าง

ไคลเอนต์ไม่เดาความสามารถของโมเดลจากชื่อของมันเด็ดขาด แต่จะอ่าน **capability runtime** —
ชุด recipe ที่อธิบายว่าสำหรับผู้ให้บริการ transport และความสามารถหนึ่ง ๆ ต้องเขียน JSON pointer
ตัวไหนลงในคำขอบ้าง recipe เหล่านั้นอยู่ใน
[`shared/capabilityrecipe`](../../shared/capabilityrecipe/) และถูกนำไปใช้โดย
`CapabilityRecipeRequestCompiler`

ขากลับ `CapabilityExecutionRuntime` จะบันทึกว่าเกิดอะไรขึ้นจริง มีเพียง stream parser
ในเส้นทางโปรดักชันที่ถูกเลือกไว้เท่านั้นที่เลื่อนสถานะความสามารถเป็น *observed* ได้ HTTP 200
คำตอบที่ไม่ว่างเปล่า และการประกาศ tool ในคำขอ **ไม่ถือเป็นหลักฐาน** อย่างชัดเจน
สถานะสุดท้ายถูกเก็บแยกรายข้อความ UI จึงบอกคุณได้ว่ามีการร้องขอตัวควบคุมหนึ่งไป
แต่ไม่เคยได้รับการยืนยัน แทนที่จะทำเป็นเงียบ ๆ ว่ามันทำงานสำเร็จ

## การจัดเก็บข้อมูล

```
Application Support/Oriveo/
  active-uid                     # storage partition, "guest" by default
  users/<uid>/
    oriveo.sqlite                # conversations, messages, notes and folders, catalog cache
    Images/  Files/              # attachment blobs, referenced by id
    session-snapshot.json        # preferences, provider list, folders, last used model
```

- **SQLite ผ่าน GRDB** โดยเปิด WAL เปิด foreign key และมี `DatabaseMigrator`
  ครอบคลุมทุกการเปลี่ยนแปลงของ schema การค้นหาแบบ full-text ในข้อความและโน้ตใช้ FTS5
  กับ trigram tokenizer
- **API key อยู่ใน Keychain** แยกตามผู้ให้บริการและพาร์ทิชัน
  และถูกลบออกจาก session snapshot ก่อนที่ snapshot นั้นจะถูกเขียนลงดิสก์
  ส่วนทักษะถูกเก็บแยกเป็น JSON ใน `UserDefaults`
- **ไฟล์แนบเป็นไฟล์บนดิสก์** ไม่ใช่แถวในตาราง ไฟล์ PDF ขนาดใหญ่จึงไม่ทำให้ฐานข้อมูลบวม

ไฟล์สำรองข้อมูลคือ ZIP นามสกุล `.oriveo` ที่บรรจุ `data.json` พร้อมไฟล์รูปภาพ
รหัสผ่านที่ตั้งได้นั้นไม่ได้เข้ารหัสตัวไฟล์สำรองทั้งก้อน มันเข้ารหัสเฉพาะ API key
ของผู้ให้บริการที่อยู่ข้างใน (AES-GCM โดยคีย์ได้มาจาก PBKDF2-HMAC-SHA256 จำนวน 600,000 รอบ)
ไม่ว่าจะตั้งรหัสผ่านหรือไม่ บทสนทนา โน้ต ทักษะ และการตั้งค่า ก็ยังเป็น JSON ธรรมดาในไฟล์สำรอง
ดังนั้นให้ถือว่าไฟล์สำรองเป็นสิ่งที่ใครได้ไปก็อ่านได้

## แคตตาล็อกโมเดล

ตอนเปิดแอปแบบ cold start แอปจะยิงคำขอ `GET` แบบไม่ต้องยืนยันตัวตนและมีเงื่อนไข ETag หนึ่งรายการ
ไปยัง `https://api.oriveoai.com/api/metadata?view=lean` มันดึงแคตตาล็อกโมเดลสาธารณะ
ว่ามีโมเดลอะไรบ้าง แต่ละตัวรองรับอะไร ตัวควบคุมการให้เหตุผลของมันชื่ออะไร และราคาเท่าไร ไม่มีคีย์
ไม่มีบทสนทนา และไม่มีตัวระบุตัวตนแนบไปด้วย ส่วนคำตอบถูกแคชไว้ใน SQLite
แอปจึงทำงานจากสำเนาที่แคชไว้ได้เมื่อเข้าถึงแคตตาล็อกไม่ได้ ส่วนปลายทางที่สอง
`/api/metadata/model-facts` จะถูกอ่านเฉพาะหลังจากคุณเข้าสู่ระบบด้วยแพ็กเกจสมาชิก ChatGPT หรือ Grok
เพื่อดูว่าโมเดลของแพ็กเกจนั้นทำอะไรได้

นี่คือคำขอทั้งหมดที่แอปส่งในนามของตัวเอง ที่เหลือทั้งหมดวิ่งไปหาผู้ให้บริการที่คุณตั้งค่าไว้
ด้วยคีย์ของคุณ

การชี้แคตตาล็อกไปยังโฮสต์ของคุณเองเป็น**ความสะดวกของบิลด์แบบ Debug** ซึ่ง
`Oriveo/Core/Providers/BackendURLResolver.swift` แก้ค่าตามลำดับนี้:

1. ตัวแปรสภาพแวดล้อม `ORIVEO_METADATA_BASE_URL` ที่ตั้งไว้ใน Run action ของ scheme แล้วจึง
2. สตริง `ORIVEO_METADATA_BASE_URL` ใน `ios/Oriveo/Config/Info.plist` — คีย์นี้อยู่ที่นั่นแล้ว
   และปล่อยว่างไว้ แค่เติมค่าลงไปก็พอ แล้วจึง
3. `https://api.oriveoai.com`

มีสองเรื่องที่ควรรู้ บิลด์แบบ Release จะไม่สนใจทั้งสองอย่างและใช้แคตตาล็อกที่เผยแพร่ไว้เสมอ
ถ้าจะเปลี่ยนพฤติกรรมนั้นต้องไปแก้ `BackendURLResolver` และอีกเรื่องคือ เมื่อ test bundle กำลังรัน
หรือเมื่อมี `CI=true` ค่าที่ตั้งทับซึ่งชี้ไปยังที่อยู่ส่วนตัว (localhost, `10/8`, `192.168/16`,
`172.16/12`, `.local`, IPv6 แบบ link-local) จะถูกละเลย
โฮสต์ในเครื่องที่ค้างอยู่จึงไม่ทำให้ชุดทดสอบต้องพึ่งพาเครื่องที่คุณกำลังนั่งอยู่หน้ามัน

## โครงสร้างโปรเจกต์

```
ios/Oriveo/
  Config/Info.plist    the app's Info.plist; GENERATE_INFOPLIST_FILE is off
  Oriveo.xcodeproj/
  Oriveo/
    Core/
      Providers/       15 provider services, transports, capability runtime, catalog client
      State/           AppState and the managers it owns
      Database/        GRDB pool, schema, migrator, stores, observations
      Models/          domain types
      Attachments/     import limits, budgets, per-format text extraction
      Tools/           tool-call loop and per-protocol adapters
      Cache/ Localization/ Observability/ Reachability/ Routing/ Usage/
    Features/
      App/             root view and tab shell
      Chat/            transcript, composer, model controls, cross-check, export
      Providers/       setup, detail, relay, local engines, subscription sign-in
      Home/ Notes/ Skills/ Settings/ Backup/ Onboarding/
    Shared/Components/ shared views
    DesignSystem/      theme, colour, haptics
    Preview/           sample data for SwiftUI previews
    *.xcstrings        ten string catalogs
    Assets.xcassets · PrivacyInfo.xcprivacy · Oriveo.entitlements
  OriveoTests/
```

## บิลด์และรัน

คุณต้องมี **Xcode 26** และถ้าจะรันบนเครื่องจริงก็ต้องมีอุปกรณ์ที่รัน **iOS 18 ขึ้นไป** บัญชี Apple
Developer แบบฟรีก็เพียงพอ ไฟล์ entitlements เป็นไฟล์เปล่า และแอปไม่ได้ใช้ capability ที่ต้องเสียเงิน
— ไม่มี push ไม่มี iCloud ไม่มี app group ไม่มี associated domain

ขั้นต่ำที่รูปแบบไฟล์โปรเจกต์และเวอร์ชันของ Swift tools บังคับจริง ๆ คือ Xcode 16.3 แต่ target นี้ตั้ง
`SWIFT_APPROACHABLE_CONCURRENCY` และ `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` ไว้
ซึ่ง Xcode รุ่นเก่ากว่าจะละเลยมันโดยไม่บอกอะไรเลย
การให้ actor isolation ถูกเปลี่ยนไปเงียบ ๆ ไม่ใช่วิธีที่ดีในการรู้เรื่องนี้ จึงควรบิลด์ด้วย Xcode 26

1. เปิด `ios/Oriveo/Oriveo.xcodeproj`
2. เลือก scheme ชื่อ `Oriveo`
3. ใต้ **Signing & Capabilities** เลือก Team ของคุณเอง
4. ถ้า Xcode ลงทะเบียน `ai.oriveo.community` ไม่ได้ ให้เปลี่ยน bundle identifier
   เป็นชื่อที่ทีมของคุณเป็นเจ้าของ
5. เสียบ iPhone เปิด Developer Mode กด trust เครื่องคอมพิวเตอร์ แล้วกด Run

ถ้าจะบิลด์ลงซิมูเลเตอร์แทน ให้เลือกซิมูเลเตอร์ iPhone ตัวใดก็ได้แล้วกด Run
ส่วน dependency ของ package จะถูก resolve จาก `Package.resolved` ที่ commit ไว้

**บน Mac ที่ใช้ Apple silicon** บิลด์สำหรับ iPhone ก็รันแบบเนทีฟได้ด้วย โดยเลือกปลายทาง
**My Mac (Designed for iPad)** ส่วน Mac Catalyst ไม่ได้เปิดใช้ — โปรเจกต์ไม่เคยเลือกใช้มัน
และ `TARGETED_DEVICE_FAMILY` ยังคงเป็น `1,2` — ฉะนั้นนี่คือแอป iOS
ที่รันอยู่ใต้รันไทม์ความเข้ากันได้ของ iPad ไม่ใช่แอปของ Mac
และเส้นทางที่มีแต่บนอุปกรณ์ เช่น การถ่ายภาพด้วยกล้อง จึงทำงานแบบเดียวกับที่มันทำบน Mac

ไฟล์โปรเจกต์ใช้ `objectVersion = 77` พร้อม file-system synchronized group
ดังนั้น Xcode รุ่นเก่ากว่านี้อาจไม่ยอมเปิด ให้อัปเดต Xcode แทนที่จะไปแก้รูปแบบไฟล์โปรเจกต์

> [!NOTE]
> เป้าหมายของแอปคอมไพล์ในโหมดภาษา Swift 5 ส่วน package `OriveoProviderKit` ในเครื่องประกาศ
> `swift-tools-version: 6.1` และบิลด์ในโหมดภาษา Swift 6

## ไลบรารีที่ใช้

| Package | เวอร์ชัน | ใช้ทำอะไร |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | เข้าถึง SQLite, migration, `ValueObservation` |
| [ChatLayout](https://github.com/ekazaev/ChatLayout) | 2.4.3 | เลย์เอาต์ collection view ของ transcript |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.4.1 | เรนเดอร์ Markdown |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | เรนเดอร์ LaTeX |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | ไฟล์สำรองข้อมูล, แตกข้อความจาก Office/EPUB/ODF |
| `OriveoProviderKit` | ในเครื่อง | เคอร์เนล wire ของผู้ให้บริการ อยู่ใน [`shared/`](shared.md) |

`Package.resolved` ยังตรึง dependency ทางอ้อมสองตัวที่ swift-markdown-ui ลากมาด้วย ได้แก่
[NetworkImage](https://github.com/gonzalezreal/NetworkImage) 6.0.1 และ
[swift-cmark](https://github.com/swiftlang/swift-cmark) 0.8.0 dependency ตรงทุกตัวใช้สัญญาอนุญาต MIT
ส่วน swift-cmark เป็น BSD-2-Clause ทั้งหมดเข้ากันได้กับ AGPL-3.0-or-later

## การทดสอบ

รัน test action (⌘U) ของ scheme `Oriveo` ใน Xcode หรือรันจากรากของที่เก็บโค้ด:

```bash
xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

เปลี่ยนไปใช้ซิมูเลเตอร์ที่คุณมีจริง ส่วน `xcodebuild -showdestinations` ที่ใช้ project และ scheme
เดียวกัน จะแสดงทุกปลายทางที่ checkout ชุดนี้บิลด์ได้

> [!IMPORTANT]
> เป้าหมายทดสอบอ่าน contract fixture จาก `shared/` โดยไล่ขึ้นไปจาก `#filePath`
> จนกว่าจะเจอไดเรกทอรีนั้น ดังนั้น
> **เทสต์จะผ่านก็ต่อเมื่อ checkout มาทั้งที่เก็บโค้ด** — คัดลอกเฉพาะ `ios/` ออกไปจะไม่ทำงาน

ชุดทดสอบมีขนาดใหญ่ ราว 2,900 เคสของ [Swift Testing](https://github.com/swiftlang/swift-testing)
บวกอีก 76 เคสของ XCTest กระจายอยู่ใน 275 ไฟล์ ครอบคลุมรูปแบบคำขอรายผู้ให้บริการ
การเล่นซ้ำ SSE จาก upstream ที่บันทึกไว้ นโยบายของ relay และเอนจินในเครื่อง
การวัดขนาด transcript และพฤติกรรมการสตรีม การจัดเก็บข้อมูล และการสำรอง–กู้คืนแบบไปกลับ

`shared/OriveoProviderKit` มีชุดทดสอบของตัวเอง:

```bash
cd shared/OriveoProviderKit && swift test
```

## การแปลภาษา

สิบหกภาษา เก็บเป็น Xcode String Catalog (`.xcstrings`) — สิบแคตตาล็อก คีย์ราว 1,340 รายการ
โดยใช้ภาษาอังกฤษเป็นต้นทาง ทุกคีย์ถูกแปลครบทั้งสิบหกภาษา
ยกเว้นไม่กี่รายการที่ทำเครื่องหมาย `shouldTranslate: false` ไว้ ได้แก่ ชื่อผลิตภัณฑ์ เครื่องหมายวรรคตอน
โครงรูปแบบ และค่าของโปรโตคอลที่แปลไปแล้วจะผิด สตริงถูก resolve ผ่าน `L10n.tr(_:table:)` จาก bundle
`.lproj` ที่เลือกตามการตั้งค่าภาษาในแอปของผู้ใช้ การสลับภาษาจึงมีผลทันทีโดยไม่ต้องเปิดแอปใหม่
ส่วนเลย์เอาต์ขวาไปซ้ายสำหรับภาษาอาหรับถูกจัดการไว้อย่างชัดเจน

## การมีส่วนร่วม

ดู [CONTRIBUTING.md](../../CONTRIBUTING.md) ถ้าเปลี่ยนพฤติกรรม ให้เพิ่มเทสต์มาด้วย
สำหรับการแก้โปรโตคอลของผู้ให้บริการ ควรใช้ fixture ที่บันทึกไว้ใต้ `shared/test-fixtures`
มากกว่าการเขียน mock ขึ้นเอง และระบุด้วยว่าคุณทดสอบกับผู้ให้บริการและโมเดลตัวไหน

## สัญญาอนุญาต

[AGPL-3.0-or-later](../../LICENSE)
