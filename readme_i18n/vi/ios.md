<div align="center">

# Oriveo cho iOS

**Một client chat SwiftUI native cho những mô hình AI bạn vốn đã trả tiền để dùng.**

<a href="../../LICENSE"><img alt="Giấy phép AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="iOS 18 trở lên" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white">
<img alt="Dựng bằng Swift" src="https://img.shields.io/badge/Swift-6.1_package_·_Xcode_26-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="16 ngôn ngữ giao diện" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

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
**Tiếng Việt** ·
<a href="../zh-Hans/ios.md">简体中文</a> ·
<a href="../zh-Hant/ios.md">繁體中文</a>

</sub>

</div>

---

Client iOS của Oriveo là một ứng dụng chat AI theo mô hình bring-your-own-key. Bạn thêm những khóa
API mà bạn đã sở hữu, và ứng dụng gọi thẳng từng nhà cung cấp ngay từ điện thoại. Cuộc trò chuyện,
ghi chú, thư mục, kỹ năng và tệp đính kèm được lưu trên thiết bị trong SQLite; khóa API đi vào iOS
Keychain. Không có tài khoản và không cần đăng nhập.

Đây là một phần của [Oriveo Community Edition](README.md) — ba client dùng chung một định nghĩa duy
nhất về cách nói chuyện với nhà cung cấp mô hình.

## Kiến trúc

```mermaid
flowchart TB
    subgraph ui ["Lớp trình bày"]
        direction LR
        swiftui["SwiftUI<br/>NavigationStack · AppRoute"]
        uikit["Transcript UIKit<br/>UICollectionView · ChatLayout"]
    end

    appstate["AppState · @Observable<br/>ChatManager · ProviderManager · NoteManager · SkillManager"]

    subgraph store ["Trên thiết bị"]
        direction LR
        grdb[("SQLite · GRDB")]
        keychain[["Keychain · khóa API"]]
        files[("Ảnh · Tệp")]
    end

    subgraph provider ["Lớp nhà cung cấp"]
        direction LR
        services["15 ProviderService<br/>relay dùng lại cái của OpenAI"]
        transports["TransportRegistry<br/>12 chiến lược"]
        kit["OriveoProviderKit<br/>SSE · ghép chunk · che khóa"]
    end

    swiftui & uikit <--> appstate
    appstate <--> grdb & keychain & files
    appstate --> services
    services --> transports --> kit
    kit ==>|"khóa của bạn"| up["Nhà cung cấp mô hình"]
```

Có ba điều trong sơ đồ này đáng nói thẳng ra.

**Transcript là UIKit, phần còn lại là SwiftUI.** `ChatView` nhúng một
`ChatListViewControllerRepresentable` bọc quanh một `UICollectionView` do
[ChatLayout](https://github.com/ekazaev/ChatLayout) điều khiển. Mọi thứ khác — điều hướng, cài đặt,
thiết lập nhà cung cấp, ghi chú, kỹ năng — đều là SwiftUI. Sự tách đôi này tồn tại vì một transcript
streaming ở tốc độ token cần mức kiểm soát đo đạc và tái sử dụng ở từng cell mà cơ chế diffing của
SwiftUI không cho được. Ranh giới đó được ghi lại trong
[`Features/Chat/ARCHITECTURE.md`](../../ios/Oriveo/Oriveo/Features/Chat/ARCHITECTURE.md).

**Có ba đường độc lập cùng cập nhật transcript đó**, và đó là chủ ý.

| Đường đi | Mang gì | Vì sao |
|---|---|---|
| `@Observable AppState` | thay đổi về cấu trúc — một tin nhắn xuất hiện, một cuộc trò chuyện được chuyển | thuần SwiftUI, rẻ với những sự kiện tần suất thấp |
| GRDB `ValueObservation` | trạng thái bền vững đọc ngược lại từ SQLite | một nguồn sự thật duy nhất sau khi ghi, còn nguyên sau khi khởi động lại |
| Combine `PassthroughSubject` cho mỗi cuộc trò chuyện | văn bản streaming và các delta suy luận | né hoàn toàn diffing của SwiftUI ở tốc độ token |

**Hỗ trợ nhà cung cấp là bốn trục độc lập, không phải một enum.** `ProviderKind` (16 trường hợp) là
*người dùng đã cấu hình cái gì*. `ProviderServiceProtocol` là *bề mặt gọi*. `TransportKind`
(12 trường hợp) là *giao thức wire thực sự được nói* — và nó được quyết định **theo từng mô hình,
từ danh mục**, nên hai mô hình sau cùng một khóa vẫn có thể khác nhau. `RelayKind` lo các endpoint
do người dùng tự cung cấp. Chính việc giữ chúng tách biệt là thứ khiến một mô hình mới chạy được mà
không cần bản dựng mới.

### Một tin nhắn được gửi đi như thế nào

```mermaid
flowchart LR
    ui["Ô soạn thảo"] --> build["ChatRequestSnapshot<br/>prompt · bộ nhớ · ghi chú · tệp đính kèm"]
    build --> recipes["Công thức khả năng<br/>lấy từ danh mục"]
    recipes --> encode["encodeChatBody<br/>ranh giới wire duy nhất"]
    encode ==>|"khóa của bạn"| up(["Nhà cung cấp mô hình"])
    up ==> parse["TransportStrategy<br/>+ bộ ghép OriveoProviderKit"]
    parse --> cells["Transcript streaming"]
```

`BaseAPIService.encodeChatBody` là điểm duy nhất nơi thân yêu cầu trở thành byte. Mọi công thức khả
năng, mọi tham số sinh và mọi trường tùy chỉnh đều phải đi qua đó, và chính điều này làm cho định
dạng wire có thể kiểm thử ở một chỗ thay vì mười lăm chỗ.

## Mô hình được phép làm gì

Client không bao giờ đoán khả năng của một mô hình từ tên của nó. Nó đọc một **capability runtime** —
một tập công thức mô tả, với một nhà cung cấp, một transport và một khả năng cụ thể, chính xác những
JSON pointer nào cần ghi vào yêu cầu. Các công thức đó nằm trong
[`shared/capabilityrecipe`](../../shared/capabilityrecipe/) và được
`CapabilityRecipeRequestCompiler` áp dụng.

Ở chiều về, `CapabilityExecutionRuntime` ghi lại điều thực sự đã xảy ra. Chỉ một bộ phân tích luồng
trên đường chạy production đã được chọn mới có quyền nâng một khả năng lên mức *observed*. Một HTTP
200, một câu trả lời không rỗng, và một khai báo công cụ trong yêu cầu đều **không phải bằng chứng**,
điều này được nói rõ. Trạng thái cuối được lưu theo từng tin nhắn, nên giao diện có thể nói cho bạn
biết rằng một điều khiển đã được yêu cầu nhưng chưa bao giờ được xác nhận, thay vì lặng lẽ ngụ ý
rằng nó đã hoạt động.

## Lưu trữ

```
Application Support/Oriveo/
  active-uid                     # storage partition, "guest" by default
  users/<uid>/
    oriveo.sqlite                # conversations, messages, notes, catalog cache
    Images/  Files/              # attachment blobs, referenced by id
    session-snapshot.json        # preferences, provider list (never API keys)
```

- **SQLite thông qua GRDB** với WAL, bật khóa ngoại, và một `DatabaseMigrator` bao trọn mọi thay đổi
  schema. Tìm kiếm toàn văn trên tin nhắn và ghi chú dùng FTS5 với bộ tách từ trigram.
- **Khóa API nằm trong Keychain**, đánh chỉ mục theo nhà cung cấp và phân vùng, và bị xóa trắng khỏi
  session snapshot trước khi snapshot được ghi xuống.
- **Tệp đính kèm là các tệp trên đĩa**, không phải hàng trong bảng, nên một file PDF lớn không bao
  giờ làm phình cơ sở dữ liệu.

## Lệnh gọi mạng duy nhất ứng dụng tự thực hiện

Khi khởi động nguội, ứng dụng phát hai yêu cầu `GET` không cần xác thực, có điều kiện ETag, tới
`https://api.oriveoai.com` — `/api/metadata?view=lean` và `/api/metadata/model-facts`. Chúng tải
danh mục mô hình công khai: có những mô hình nào, mỗi mô hình hỗ trợ gì, các điều khiển suy luận của
nó tên là gì, và giá bao nhiêu. Không kèm khóa, không kèm cuộc trò chuyện và không kèm định danh, và
phản hồi được lưu đệm trong SQLite nên ứng dụng vẫn chạy từ bản đệm khi không với tới được danh mục.

Đây là yêu cầu duy nhất ứng dụng thực hiện cho chính nó. Mọi thứ khác đều đi tới một nhà cung cấp mà
bạn đã cấu hình, bằng khóa của bạn.

Muốn trỏ một bản dựng **Debug** về host danh mục của riêng bạn thì hãy đặt
`ORIVEO_METADATA_BASE_URL` — hoặc như một biến môi trường của scheme, hoặc như một khóa trong
`ios/Oriveo/Config/Info.plist`. Khác với client Android và web, bản dựng Release bỏ qua nó và luôn
dùng danh mục đã phát hành; muốn đổi điều đó thì phải sửa `BackendURLResolver`.

## Cấu trúc dự án

```
ios/Oriveo/
  Oriveo.xcodeproj/
  Oriveo/
    Core/
      Providers/       15 provider services, transports, capability runtime, catalog client
      State/           AppState and the managers it owns
      Database/        GRDB pool, schema, migrator, stores, observations
      Models/          domain types
      Attachments/     import limits, budgets, per-format text extraction
      Tools/           tool-call loop and per-protocol adapters
    Features/
      Chat/            transcript, composer, model controls, export
      Providers/       setup, detail, relay, local engines, subscription sign-in
      Home/ Notes/ Skills/ Settings/ Backup/ Onboarding/
    Shared/Components/ shared views
    DesignSystem/      theme, colour, haptics
  OriveoTests/
```

## Dựng và chạy

Bạn cần một máy Mac có **Xcode 26** và một thiết bị chạy **iOS 18 trở lên**. Tài khoản Apple
Developer miễn phí là đủ; ứng dụng không dùng capability trả phí nào và đi kèm một tệp entitlements
rỗng.

1. Mở `ios/Oriveo/Oriveo.xcodeproj`
2. Chọn scheme `Oriveo`
3. Trong **Signing & Capabilities**, chọn Team của bạn
4. Nếu Xcode không đăng ký được `ai.oriveo.community`, hãy đổi bundle identifier sang một định danh
   mà nhóm của bạn sở hữu
5. Cắm iPhone, bật Developer Mode, tin cậy máy tính, rồi nhấn Run

Nếu muốn dựng cho Simulator, chọn bất kỳ simulator iPhone nào rồi nhấn Run. Các phụ thuộc package
được resolve từ tệp `Package.resolved` đã commit.

Tệp dự án dùng `objectVersion = 77` với các nhóm đồng bộ theo hệ thống tệp, nên một bản Xcode cũ hơn
có thể từ chối mở nó. Hãy cập nhật Xcode thay vì sửa định dạng dự án.

> [!NOTE]
> Target ứng dụng biên dịch ở chế độ ngôn ngữ Swift 5 với `SWIFT_APPROACHABLE_CONCURRENCY` và
> `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Package `OriveoProviderKit` cục bộ khai báo
> `swift-tools-version: 6.1` và được dựng ở chế độ ngôn ngữ Swift 6.

## Phụ thuộc

| Package | Phiên bản | Dùng để |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | truy cập SQLite, migration, `ValueObservation` |
| [ChatLayout](https://github.com/ekazaev/ChatLayout) | 2.4.3 | bố cục collection view của transcript |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.4.1 | kết xuất Markdown |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | kết xuất LaTeX |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | kho lưu trữ sao lưu, bóc tách Office/EPUB/ODF |
| `OriveoProviderKit` | cục bộ | nhân wire của nhà cung cấp, trong [`shared/`](shared.md) |

## Kiểm thử

Chạy test action (⌘U) của scheme `Oriveo` trong Xcode, hoặc từ thư mục gốc của kho mã:

```bash
xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Hãy thay bằng một simulator bạn thực sự có — `xcrun simctl list devices available` liệt kê chúng.

> [!IMPORTANT]
> Target kiểm thử đọc các contract fixture từ `shared/` bằng cách đi ngược lên từ `#filePath` cho
> tới khi tìm thấy thư mục đó. Khoảng 29 bộ test phụ thuộc vào nó, nên **các bài test chỉ chạy đúng
> khi bạn checkout toàn bộ kho mã** — sao chép riêng thư mục `ios/` ra sẽ không hoạt động.

Bộ test rất lớn: khoảng 2.900 bài test trải trên 273 tệp, chủ yếu dùng
[Swift Testing](https://github.com/swiftlang/swift-testing). Nó bao phủ hình dạng yêu cầu theo từng
nhà cung cấp, phát lại SSE upstream đã ghi, chính sách relay và engine cục bộ, việc đo đạc transcript
và hành vi streaming, lưu trữ, và các vòng sao lưu — khôi phục.

`shared/OriveoProviderKit` có bộ test riêng:

```bash
cd shared/OriveoProviderKit && swift test
```

## Bản địa hóa

Mười sáu ngôn ngữ, lưu dưới dạng Xcode String Catalog (`.xcstrings`) — mười catalog, khoảng 1.900
khóa, tiếng Anh là nguồn. Chuỗi được phân giải qua `L10n.tr(_:table:)` dựa trên một bundle `.lproj`
chọn theo thiết lập ngôn ngữ trong ứng dụng, nên đổi ngôn ngữ có hiệu lực ngay mà không cần khởi
động lại. Bố cục phải-sang-trái cho tiếng Ả Rập được xử lý một cách tường minh.

## Đóng góp

Xem [CONTRIBUTING.md](../../CONTRIBUTING.md). Có thay đổi hành vi thì thêm một bài test; với một bản
sửa giao thức nhà cung cấp, hãy ưu tiên một fixture đã ghi trong `shared/test-fixtures` hơn là một
mock viết tay, và nói rõ bạn đã thử với nhà cung cấp và mô hình nào.

## Giấy phép

[AGPL-3.0-or-later](../../LICENSE).
