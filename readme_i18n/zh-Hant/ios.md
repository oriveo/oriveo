<div align="center">

# Oriveo for iOS

**一個原生 SwiftUI 聊天用戶端，用來使用你早就在付費的那些 AI 模型。**

<a href="../../LICENSE"><img alt="授權條款 AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="iOS 18 以上" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white">
<img alt="以 Swift 打造" src="https://img.shields.io/badge/Swift-6.1_package_·_Xcode_26-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="16 種介面語言" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

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
<a href="../th/ios.md">ไทย</a> ·
<a href="../tr/ios.md">Türkçe</a> ·
<a href="../vi/ios.md">Tiếng Việt</a> ·
<a href="../zh-Hans/ios.md">简体中文</a> ·
**繁體中文**

</sub>

</div>

---

Oriveo iOS 用戶端是一個自備金鑰的 AI 聊天應用程式。你加入自己既有的 API Key，應用程式就從手機直接
呼叫每一家供應商。對話、訊息、筆記與筆記資料夾住在裝置上的一個 SQLite 資料庫裡；附件的二進位內容是
擺在它旁邊的檔案；技能、偏好設定、供應商清單與對話資料夾則是裝置上的 JSON。API Key 則交給 iOS
Keychain。

沒有 Oriveo 帳號：什麼都不會上傳，也沒有東西可以登入。確實有兩家供應商可以用你既有的訂閱登入，而不必
貼上 Key —— ChatGPT 與 Grok —— 而那個登入是去 OpenAI 與 xAI，不是來我們這裡。

它是 [Oriveo 社群版](README.md) 的一部分 —— 三個用戶端共用同一份「該怎麼跟模型供應商說話」的定義。

## 架構

```mermaid
flowchart TB
    subgraph ui ["呈現層"]
        direction LR
        swiftui["SwiftUI<br/>NavigationStack · AppRoute"]
        uikit["UIKit 訊息列表<br/>UICollectionView · ChatLayout"]
    end

    appstate["AppState · @Observable<br/>ChatManager · ProviderManager · NoteManager · SkillManager"]

    subgraph store ["裝置本機"]
        direction LR
        grdb[("SQLite · GRDB")]
        keychain[["Keychain · API Key"]]
        files[("圖片 · 檔案")]
    end

    subgraph provider ["供應商層"]
        direction LR
        services["15 個 ProviderService<br/>中轉站沿用 OpenAI 那個"]
        transports["TransportRegistry<br/>12 種策略"]
        kit["OriveoProviderKit<br/>SSE · chunk 組裝 · 憑證遮蔽"]
    end

    swiftui & uikit <--> appstate
    appstate <--> grdb & keychain & files
    appstate --> services
    services --> transports --> kit
    kit ==>|"你的 Key"| up["模型供應商"]
```

這張圖有三件事值得明講。

**訊息列表是 UIKit，其餘都是 SwiftUI。** `ChatView` 內嵌了一個包住 `UICollectionView` 的
`ChatListViewControllerRepresentable`，由 [ChatLayout](https://github.com/ekazaev/ChatLayout)
驅動。其他所有東西 —— 導覽、設定、供應商設定、筆記、技能 —— 都是 SwiftUI。之所以拆開，是因為以
token 速率更新的串流訊息列表，需要對量測與重用做到 cell 層級的掌控，而 SwiftUI 的 diff 給不了這件事。
[`Features/Chat/ARCHITECTURE.md`](../../ios/Oriveo/Oriveo/Features/Chat/ARCHITECTURE.md)
記錄了這條邊界。

**有三條各自獨立的路徑在更新那個訊息列表**，這是刻意的：

| 路徑 | 承載什麼 | 為什麼 |
|---|---|---|
| `@Observable AppState` | 結構性變化 —— 出現一則訊息、切換一個對話 | SwiftUI 原生，低頻事件下成本很低 |
| GRDB `ValueObservation` | 從 SQLite 讀回來的持久狀態 | 寫入之後只有一個真相來源，重新啟動也還在 |
| 每個對話一個 Combine `PassthroughSubject` | 串流文字與推理增量 | 在 token 速率下完全繞開 SwiftUI 的 diff |

**供應商支援是四條互相獨立的軸，不是一個 enum。** `ProviderKind`（16 個 case：十五家供應商加上
中轉站（Relay））是*使用者設定了誰*。
`ProviderServiceProtocol` 是*呼叫介面*。`TransportKind`（12 個 case）是*實際說的是哪一種通訊協定* ——
而且它是**依模型、從目錄解析出來的**，所以同一把 Key 後面的兩個模型完全可以不一致。`RelayKind` 負責
使用者自備的端點。把它們分開，正是新模型不必重新建置就能用的原因。

### 一則訊息是怎麼送出去的

```mermaid
flowchart LR
    ui["輸入框"] --> build["ChatRequestSnapshot<br/>提示詞 · 記憶 · 筆記 · 附件"]
    build --> recipes["能力配方<br/>從目錄解析而來"]
    recipes --> encode["encodeChatBody<br/>唯一的通訊邊界"]
    encode ==>|"你的 Key"| up(["模型供應商"])
    up ==> parse["TransportStrategy<br/>+ OriveoProviderKit 組裝器"]
    parse --> cells["串流訊息列表"]
```

`BaseAPIService.encodeChatBody` 是一個 OpenAI 相容請求變成位元組之前的最後一站 —— 十六個 case 裡有
十二個從這裡通過，所以一條能力配方、一個生成參數或一個自訂欄位能在一個地方而不是十二個地方被測試。
OpenAI、Anthropic 與 Gemini 說的是它們自己的形狀，在各自的 service 裡序列化；這幾處各有自己的一套
請求形狀測試。

## 模型被允許做什麼

用戶端從不從模型名稱去猜它的能力。它讀取一套**能力執行期** —— 一組配方，描述在給定的供應商、傳輸
方式與能力下，究竟該把哪些 JSON pointer 寫進請求裡。這些配方放在
[`shared/capabilityrecipe`](../../shared/capabilityrecipe/)，
由 `CapabilityRecipeRequestCompiler` 套用。

在回程上，`CapabilityExecutionRuntime` 記錄實際發生了什麼。只有被選定的正式串流解析器可以把一項能力
提升為*已觀測*。HTTP 200、一個非空的答案，以及請求裡的工具宣告，都明確**不算證據**。終端狀態依訊息
保存，所以介面能告訴你某個控制項曾被請求但從未被確認，而不是默默暗示它成功了。

## 儲存

```
Application Support/Oriveo/
  active-uid                     # storage partition, "guest" by default
  users/<uid>/
    oriveo.sqlite                # conversations, messages, notes and folders, catalog cache
    Images/  Files/              # attachment blobs, referenced by id
    session-snapshot.json        # preferences, provider list, folders, last used model
```

- **透過 GRDB 使用 SQLite**，開啟 WAL 與外鍵，並以一個 `DatabaseMigrator` 涵蓋每一次 schema 變更。
  對訊息與筆記的全文搜尋使用 FTS5 搭配 trigram 斷詞器。
- **API Key 存在 Keychain 裡**，以供應商與分區作為鍵，並且在 session 快照寫入之前就被清空。技能
  則單獨以 JSON 存在 `UserDefaults` 裡。
- **附件是磁碟上的檔案**，不是資料列，所以一份大 PDF 永遠不會撐爆資料庫。

一份備份是一個 `.oriveo` ZIP，裡面裝著 `data.json` 加上圖片檔案。那個選用的密碼並不加密整個封存檔：
它只加密封存檔裡的供應商 API Key（AES-GCM，金鑰由 PBKDF2-HMAC-SHA256 迭代 600,000 次衍生）。不論你
設不設密碼，對話、筆記、技能 與偏好設定在封存檔裡都是純 JSON，所以請把一個備份檔當作「拿到它的人
都讀得到」來看待。

## 模型目錄

冷啟動時，應用程式會對 `https://api.oriveoai.com/api/metadata?view=lean` 發出一個未驗證、帶 ETag
條件的 `GET`。它抓取公開的模型目錄：有哪些模型、每個支援什麼、它的推理控制項叫什麼名字，以及要多少
錢。不帶 Key、不帶對話，也不帶任何識別資訊，回應會被快取在 SQLite 裡，所以目錄連不上時，應用程式仍
能靠快取副本運作。第二個端點 `/api/metadata/model-facts` 只有在你用 ChatGPT 或 Grok 訂閱登入之後才
會去讀，用來了解那個訂閱下的模型能做什麼。

這些就是應用程式為自己發出的全部請求。其餘一切都送往你設定的供應商，用你的 Key。

把目錄指向你自己的主機是**Debug 建置的一點方便**，由
`Oriveo/Core/Providers/BackendURLResolver.swift` 依下列順序解析：

1. `ORIVEO_METADATA_BASE_URL` 環境變數，在 scheme 的 Run action 裡設定；接著
2. `ios/Oriveo/Config/Info.plist` 裡名為 `ORIVEO_METADATA_BASE_URL` 的字串 —— 這個鍵已經在那裡了，
   只是空的，所以填上就夠；接著
3. `https://api.oriveoai.com`。

有兩點要知道。Release 建置會把這兩者都忽略，一律使用官方發布的目錄；想改這點，就得動
`BackendURLResolver`。還有，當測試 bundle 正在跑、或帶著 `CI=true` 時，指向私有位址（localhost、
`10/8`、`192.168/16`、`172.16/12`、`.local`、link-local IPv6）的覆寫會被忽略，這樣一個殘留的本機
主機就沒辦法讓整套測試取決於你此刻坐在哪台機器前面。

## 專案結構

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

## 建置與執行

你需要 **Xcode 26**，而要跑在實機上還需要一台 **iOS 18 以上**的裝置。免費的 Apple Developer 帳號就
夠了：entitlements 檔案是空的，而且這個應用程式沒有用到任何付費功能 —— 沒有推播、沒有 iCloud、沒有
app group、沒有 associated domain。

專案格式與 Swift tools 版本實際要求的下限是 Xcode 16.3，但這個 target 設了
`SWIFT_APPROACHABLE_CONCURRENCY` 與 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，較舊的 Xcode 會
一聲不響地忽略它們。讓 actor 隔離被悄悄改掉可不是發現這件事的好方式，所以請用 Xcode 26 建置。

1. 開啟 `ios/Oriveo/Oriveo.xcodeproj`
2. 選擇 `Oriveo` scheme
3. 在 **Signing & Capabilities** 下選擇你自己的 Team
4. 如果 Xcode 無法註冊 `ai.oriveo.community`，把 bundle identifier 改成你的團隊擁有的那種
5. 接上 iPhone、啟用開發者模式、信任這台電腦，然後執行

若要改為建置給模擬器，挑任何一個 iPhone 模擬器再執行即可。套件相依性由已提交的 `Package.resolved`
解析。

**在 Apple 晶片的 Mac 上**，這個 iPhone 建置也能原生跑起來：選擇 **My Mac (Designed for iPad)** 這個
執行目標。Mac Catalyst 並沒有啟用 —— 專案從未選用它，`TARGETED_DEVICE_FAMILY` 一直是 `1,2` ——
所以這是 iOS 應用跑在 iPad 相容執行環境裡，而不是一個 Mac 應用，像相機拍攝這類只有裝置才有的路徑，
表現就是它們在 Mac 上該有的樣子。

專案檔使用 `objectVersion = 77` 與檔案系統同步群組，因此較舊的 Xcode 可能拒絕開啟它。請更新 Xcode，
不要去改專案檔格式。

> [!NOTE]
> App target 以 Swift 5 語言模式編譯；本機的 `OriveoProviderKit` 套件宣告
> `swift-tools-version: 6.1`，以 Swift 6 語言模式建置。

## 相依套件

| 套件 | 版本 | 用途 |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | SQLite 存取、遷移、`ValueObservation` |
| [ChatLayout](https://github.com/ekazaev/ChatLayout) | 2.4.3 | 訊息列表的 collection view 版面 |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.4.1 | Markdown 渲染 |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | LaTeX 渲染 |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | 備份封存、Office/EPUB/ODF 擷取 |
| `OriveoProviderKit` | 本機 | 供應商通訊核心，位於 [`shared/`](shared.md) |

`Package.resolved` 也釘住了 swift-markdown-ui 帶進來的兩個間接相依套件：
[NetworkImage](https://github.com/gonzalezreal/NetworkImage) 6.0.1 與
[swift-cmark](https://github.com/swiftlang/swift-cmark) 0.8.0。每一個直接相依套件都是 MIT 授權，
swift-cmark 是 BSD-2-Clause，全都與 AGPL-3.0-or-later 相容。

## 測試

在 Xcode 裡執行 `Oriveo` scheme 的 test action（⌘U），或是從儲存庫根目錄執行：

```bash
xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

請換成你本機真的有的模擬器；用同樣的 project 與 scheme 跑 `xcodebuild -showdestinations`，
會列出這份 checkout 能建置的所有目標。

> [!IMPORTANT]
> 測試 target 從 `#filePath` 一路往上找到 `shared/` 目錄，再從那裡讀取契約 fixture，所以**測試只有在
> 完整 checkout 下才會通過** —— 把 `ios/` 單獨複製出去是行不通的。

這套測試很大：275 個檔案裡約有 2,900 個
[Swift Testing](https://github.com/swiftlang/swift-testing) 案例，另加 76 個 XCTest 案例。涵蓋每家
供應商的請求形狀、錄製的上游 SSE 重播、中轉站與本機引擎政策、訊息列表的量測與串流行為、儲存，以及
備份的來回一致性。

`shared/OriveoProviderKit` 有自己的一套：

```bash
cd shared/OriveoProviderKit && swift test
```

## 在地化

十六種語言，以 Xcode String Catalog（`.xcstrings`）保存 —— 十個 catalog、約 1,340 個鍵，英文是來源
語言。除了少數標了 `shouldTranslate: false` 的（產品名稱、標點、格式骨架，以及那些本來就不該被在地化
的協定取值），每一個鍵都翻成了全部十六種語言。字串透過 `L10n.tr(_:table:)` 從一個依使用者應用內語言
設定選出的 `.lproj` bundle 解析，所以切換語言不必重新啟動就會生效。阿拉伯文的由右至左版面是明確處理
的。

## 參與貢獻

見 [CONTRIBUTING.md](../../CONTRIBUTING.md)。行為變更請附上測試；修供應商協定問題時，請優先採用
`shared/test-fixtures` 底下錄製的 fixture 而不是手寫的 mock，並說明你是對哪家供應商、哪個模型測的。

## 授權條款

[AGPL-3.0-or-later](../../LICENSE)。
