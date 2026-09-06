<div align="center">

# Oriveo for iOS

**一个原生 SwiftUI 聊天客户端，用来使用你已经在付费的那些 AI 模型。**

<a href="../../LICENSE"><img alt="许可证 AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="iOS 18 及以上" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white">
<img alt="用 Swift 构建" src="https://img.shields.io/badge/Swift-6.1_package_·_Xcode_26-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="16 种界面语言" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

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
**简体中文** ·
<a href="../zh-Hant/ios.md">繁體中文</a>

</sub>

</div>

---

Oriveo iOS 客户端是一个自带 Key 的 AI 聊天 App。你添加自己已有的 API Key，App 就从手机上直接调用
每一家供应商。对话、消息、笔记和笔记文件夹住在设备上的一个 SQLite 数据库里；附件的二进制内容是它旁边
的文件；Skills、偏好设置、供应商列表和会话文件夹是设备上的 JSON。API Key 交给 iOS Keychain。

没有 Oriveo 账号：什么都不会上传，也没有可登录的东西。确实有两家供应商可以用你已有的订阅登录，
而不必粘贴 Key —— ChatGPT 和 Grok —— 而那个登录是去 OpenAI 和 xAI，不是来我们这里。

它是 [Oriveo 社区版](README.md) 的一部分 —— 三个客户端共用同一份「怎么和模型供应商说话」的定义。

## 架构

```mermaid
flowchart TB
    subgraph ui ["表现层"]
        direction LR
        swiftui["SwiftUI<br/>NavigationStack · AppRoute"]
        uikit["UIKit 消息列表<br/>UICollectionView · ChatLayout"]
    end

    appstate["AppState · @Observable<br/>ChatManager · ProviderManager · NoteManager · SkillManager"]

    subgraph store ["设备本地"]
        direction LR
        grdb[("SQLite · GRDB")]
        keychain[["Keychain · API Key"]]
        files[("图片 · 文件")]
    end

    subgraph provider ["供应商层"]
        direction LR
        services["15 个 ProviderService<br/>relay 复用 OpenAI 那个"]
        transports["TransportRegistry<br/>12 种策略"]
        kit["OriveoProviderKit<br/>SSE · 分片组装 · 脱敏"]
    end

    swiftui & uikit <--> appstate
    appstate <--> grdb & keychain & files
    appstate --> services
    services --> transports --> kit
    kit ==>|"你的 Key"| up["模型供应商"]
```

这张图里有三件事值得直说。

**消息列表是 UIKit，其余都是 SwiftUI。** `ChatView` 内嵌了一个包着 `UICollectionView` 的
`ChatListViewControllerRepresentable`，由 [ChatLayout](https://github.com/ekazaev/ChatLayout)
驱动。其它一切 —— 导航、设置、供应商配置、笔记、Skills —— 都是 SwiftUI。之所以要拆开，是因为按 token
速率刷新的流式消息列表，需要对测量和复用做到 cell 级别的控制，而 SwiftUI 的 diff 给不了这个。
[`Features/Chat/ARCHITECTURE.md`](../../ios/Oriveo/Oriveo/Features/Chat/ARCHITECTURE.md)
记录了这条边界。

**有三条独立的路径在更新这个消息列表**，这是刻意为之：

| 路径 | 承载什么 | 为什么 |
|---|---|---|
| `@Observable AppState` | 结构性变化 —— 出现一条新消息、切换一个会话 | SwiftUI 原生，低频事件下开销很小 |
| GRDB `ValueObservation` | 从 SQLite 读回来的持久状态 | 写入之后只有一个真相来源，重启也还在 |
| 每个会话一个 Combine `PassthroughSubject` | 流式文本和思考增量 | 在 token 速率下完全绕开 SwiftUI 的 diff |

**供应商支持是四条互相独立的轴，不是一个 enum。** `ProviderKind`（16 个 case：十五家供应商加上
relay）是*用户配置了谁*。
`ProviderServiceProtocol` 是*调用面*。`TransportKind`（12 个 case）是*实际说的是哪种线上协议* ——
而且它是**按模型、从目录解析出来的**，所以同一个 Key 后面的两个模型完全可以不一致。`RelayKind` 负责
用户自己提供的端点。把它们分开，正是新模型不用重新构建就能用的原因。

### 一条消息是怎么发出去的

```mermaid
flowchart LR
    ui["输入框"] --> build["ChatRequestSnapshot<br/>提示词 · 记忆 · 笔记 · 附件"]
    build --> recipes["能力配方<br/>从目录解析而来"]
    recipes --> encode["encodeChatBody<br/>唯一的协议边界"]
    encode ==>|"你的 Key"| up(["模型供应商"])
    up ==> parse["TransportStrategy<br/>+ OriveoProviderKit 组装器"]
    parse --> cells["流式消息列表"]
```

`BaseAPIService.encodeChatBody` 是一个 OpenAI 兼容请求变成字节之前的最后一站 —— 十六个 case 里有
十二个从这里过，所以一条能力配方、一个生成参数或一个自定义字段能在一个地方而不是十二个地方被测试。
OpenAI、Anthropic 和 Gemini 说的是它们自己的形状，在各自的 service 里序列化；这几处各有自己的一套
请求形状测试。

## 模型被允许做什么

客户端从不根据模型的名字去猜它的能力。它读取一套**能力运行时** —— 一组配方，描述在给定的供应商、
传输方式和能力下，究竟该往请求里写入哪些 JSON pointer。这些配方放在
[`shared/capabilityrecipe`](../../shared/capabilityrecipe/) 里，
由 `CapabilityRecipeRequestCompiler` 应用。

回来的路上，`CapabilityExecutionRuntime` 记录实际发生了什么。只有被选定的生产流解析器才可以把一项
能力提升为*已观测*。HTTP 200、一个非空的答案，以及请求里带了工具声明，都被明确规定**不算证据**。
终态按消息保存，所以 UI 能告诉你「某个开关请求过但从未被确认」，而不是默默暗示它生效了。

## 存储

```
Application Support/Oriveo/
  active-uid                     # storage partition, "guest" by default
  users/<uid>/
    oriveo.sqlite                # conversations, messages, notes and folders, catalog cache
    Images/  Files/              # attachment blobs, referenced by id
    session-snapshot.json        # preferences, provider list, folders, last used model
```

- **通过 GRDB 使用 SQLite**，开启 WAL 和外键，并用一个 `DatabaseMigrator` 覆盖每一次 schema 变更。
  对消息和笔记的全文搜索用的是 FTS5 加 trigram 分词器。
- **API Key 存在 Keychain 里**，按供应商和分区做键，写入 session 快照之前会被抹掉。Skills 单独以
  JSON 存在 `UserDefaults` 里。
- **附件是磁盘上的文件**，不是数据行，所以一个大 PDF 永远不会撑爆数据库。

备份是一个 `.oriveo` ZIP，里面装着 `data.json` 加上图片文件。那个可选的密码并不加密整个归档：它只
加密归档里的供应商 API Key（AES-GCM，密钥由 PBKDF2-HMAC-SHA256 迭代 600,000 次派生）。不论你设不设
密码，对话、笔记、Skills 和偏好设置在归档里都是明文 JSON，所以要把一个备份文件当作「拿到它的人都能
读」来对待。

## App 为自己发起的那些请求

冷启动时 App 会向 `https://api.oriveoai.com/api/metadata?view=lean` 发出一个未认证、带 ETag 条件的
`GET`。它拉取公开的模型目录：有哪些模型、每个支持什么、它的思考控制项叫什么名字，以及价格多少。
不带 Key、不带对话、不带任何标识，响应会缓存在 SQLite 里，所以目录不可达时 App 仍能靠缓存副本工作。
第二个端点 `/api/metadata/model-facts` 只有在你用 ChatGPT 或 Grok 订阅登录之后才会去读，用来了解
那个订阅下的模型能做什么。

这些就是 App 为自己发起的全部请求。其余一切都发往你配置的供应商，用你的 Key。

把目录指向你自己的服务器是**Debug 构建的一点便利**，由
`Oriveo/Core/Providers/BackendURLResolver.swift` 按下面的顺序解析：

1. `ORIVEO_METADATA_BASE_URL` 环境变量，在 scheme 的 Run action 里设置；然后
2. `ios/Oriveo/Config/Info.plist` 里名为 `ORIVEO_METADATA_BASE_URL` 的字符串 —— 这个键已经在那里
   了，只是空的，所以填上就行；然后
3. `https://api.oriveoai.com`。

有两点要知道。Release 构建会把这两者都忽略，始终使用官方发布的目录；想改这一点，就得改
`BackendURLResolver`。还有，当测试 bundle 在跑、或者带着 `CI=true` 时，指向私有地址（localhost、
`10/8`、`192.168/16`、`172.16/12`、`.local`、链路本地 IPv6）的覆盖会被忽略，这样一个残留的本地
服务器就没法让整套测试依赖你此刻坐在哪台机器前面。

## 工程结构

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

## 构建与运行

你需要 **Xcode 26**，而要跑在真机上还需要一台 **iOS 18 或更高版本**的设备。免费的 Apple Developer
账号就够了：entitlements 文件是空的，这个 App 不用任何付费能力 —— 没有推送、没有 iCloud、没有
app group、没有 associated domain。

工程格式和 Swift tools 版本实际要求的下限是 Xcode 16.3，但这个 target 设了
`SWIFT_APPROACHABLE_CONCURRENCY` 和 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，更旧的 Xcode 会
一声不响地忽略它们。让 actor 隔离被悄悄改掉可不是发现这件事的好方式，所以请用 Xcode 26 构建。

1. 打开 `ios/Oriveo/Oriveo.xcodeproj`
2. 选择 `Oriveo` scheme
3. 在 **Signing & Capabilities** 里选你自己的 Team
4. 如果 Xcode 无法注册 `ai.oriveo.community`，把 bundle identifier 改成你的团队拥有的那种
5. 连上 iPhone，打开开发者模式，信任这台电脑，然后运行

想改成给模拟器构建，随便选一个 iPhone 模拟器再运行。包依赖从已提交的 `Package.resolved` 解析。

**在 Apple 芯片的 Mac 上**，这个 iPhone 构建也能原生跑起来：选择 **My Mac (Designed for iPad)**
这个运行目标。Mac Catalyst 是刻意关掉的（`SUPPORTS_MACCATALYST = NO`），所以这是 iOS App 跑在
iPad 兼容运行时里，而不是一个 Mac App —— 像相机拍摄这类只有设备才有的路径，表现就是它们在 Mac 上
该有的样子。

工程文件用的是 `objectVersion = 77` 以及文件系统同步分组，所以更旧的 Xcode 可能拒绝打开它。请升级
Xcode，不要去改工程文件格式。

> [!NOTE]
> App target 以 Swift 5 语言模式编译；本地的 `OriveoProviderKit` 包声明
> `swift-tools-version: 6.1`，以 Swift 6 语言模式构建。

## 依赖

| 包 | 版本 | 用途 |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | SQLite 访问、迁移、`ValueObservation` |
| [ChatLayout](https://github.com/ekazaev/ChatLayout) | 2.4.3 | 消息列表的 collection view 布局 |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.4.1 | Markdown 渲染 |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | LaTeX 渲染 |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | 备份归档，Office/EPUB/ODF 解析 |
| `OriveoProviderKit` | 本地 | 供应商协议内核，位于 [`shared/`](shared.md) |

`Package.resolved` 还钉住了 swift-markdown-ui 带进来的两个间接依赖：
[NetworkImage](https://github.com/gonzalezreal/NetworkImage) 6.0.1 和
[swift-cmark](https://github.com/swiftlang/swift-cmark) 0.8.0。每一个直接依赖都是 MIT 许可，
swift-cmark 是 BSD-2-Clause，都与 AGPL-3.0-or-later 兼容。

## 测试

在 Xcode 里运行 `Oriveo` scheme 的 test action（⌘U），或者从仓库根目录运行：

```bash
xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

把模拟器换成你本机真有的那一个；用同样的 project 和 scheme 跑 `xcodebuild -showdestinations`，
会列出这份 checkout 能构建的所有目标。

> [!IMPORTANT]
> 测试 target 从 `#filePath` 一路向上找到 `shared/` 目录，再从那里读取契约 fixture，所以**测试只有
> 在完整 checkout 里才能通过** —— 把 `ios/` 单独拷出来是跑不起来的。

这套测试很大：274 个文件里约有 2,900 个
[Swift Testing](https://github.com/swiftlang/swift-testing) 用例，另加 76 个 XCTest 用例。覆盖范围
包括每家供应商的请求形状、录制的上游 SSE 回放、relay 与本地引擎策略、消息列表的测量与流式行为、
存储，以及备份的往返一致性。

`shared/OriveoProviderKit` 有自己的一套：

```bash
cd shared/OriveoProviderKit && swift test
```

## 本地化

十六种语言，以 Xcode String Catalog（`.xcstrings`）保存 —— 十个 catalog，约 1,340 个键，英语是源
语言。除了少数标了 `shouldTranslate: false` 的（产品名、标点、格式骨架，以及那些本不该被本地化的
协议取值），每一个键都翻译到了全部十六种语言。字符串通过 `L10n.tr(_:table:)` 从一个按用户 App 内
语言设置选出的 `.lproj` bundle 里解析，所以切换语言无需重启就能生效。阿拉伯语的从右到左布局是显式
处理的。

## 参与贡献

见 [CONTRIBUTING.md](../../CONTRIBUTING.md)。行为变更要配一个测试；修供应商协议问题时，优先用
`shared/test-fixtures` 下录制的 fixture 而不是手写的 mock，并说明你是对着哪家供应商、哪个模型测的。

## 许可证

[AGPL-3.0-or-later](../../LICENSE)。
