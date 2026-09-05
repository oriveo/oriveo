<div align="center">

# iOS için Oriveo

**Zaten parasını ödediğiniz yapay zekâ modelleri için yerel bir SwiftUI sohbet istemcisi.**

<a href="../../LICENSE"><img alt="AGPL-3.0-or-later lisansı" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="iOS 18 ve sonrası" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white">
<img alt="Swift ile yapılmış" src="https://img.shields.io/badge/Swift-6.1_package_·_Xcode_26-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="16 arayüz dili" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

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
**Türkçe** ·
<a href="../vi/ios.md">Tiếng Việt</a> ·
<a href="../zh-Hans/ios.md">简体中文</a> ·
<a href="../zh-Hant/ios.md">繁體中文</a>

</sub>

</div>

---

Oriveo iOS istemcisi, kendi anahtarınızı getirdiğiniz bir yapay zekâ sohbet uygulamasıdır. Zaten
sahip olduğunuz API anahtarlarını eklersiniz, uygulama da her sağlayıcıyı doğrudan telefondan
çağırır. Sohbetler, notlar, klasörler, skill'ler ve ekler cihazda SQLite içinde saklanır; API
anahtarları iOS Keychain'e gider. Hesap da yok, giriş de.

Bu, [Oriveo Community Edition](README.md)'ın bir parçasıdır — bir model sağlayıcısıyla nasıl
konuşulacağına dair tek bir tanımı paylaşan üç istemci.

## Mimari

```mermaid
flowchart TB
    subgraph ui ["Sunum"]
        direction LR
        swiftui["SwiftUI<br/>NavigationStack · AppRoute"]
        uikit["UIKit sohbet dökümü<br/>UICollectionView · ChatLayout"]
    end

    appstate["AppState · @Observable<br/>ChatManager · ProviderManager · NoteManager · SkillManager"]

    subgraph store ["Cihazda"]
        direction LR
        grdb[("SQLite · GRDB")]
        keychain[["Keychain · API anahtarları"]]
        files[("Görseller · Dosyalar")]
    end

    subgraph provider ["Sağlayıcı katmanı"]
        direction LR
        services["15 ProviderService"]
        transports["TransportRegistry<br/>12 strateji"]
        kit["OriveoProviderKit<br/>SSE · chunk birleştirme · sır gizleme"]
    end

    swiftui & uikit <--> appstate
    appstate <--> grdb & keychain & files
    appstate --> services
    services --> transports --> kit
    kit ==>|"anahtarınız"| up["Model sağlayıcı"]
```

Bu diyagramla ilgili üç şeyi açıkça söylemekte fayda var.

**Sohbet dökümü UIKit, gerisi SwiftUI.** `ChatView`, [ChatLayout](https://github.com/ekazaev/ChatLayout)
tarafından sürülen bir `UICollectionView`'ın etrafına bir
`ChatListViewControllerRepresentable` gömer. Geri kalan her şey — gezinme, ayarlar, sağlayıcı
kurulumu, notlar, skill'ler — SwiftUI'dır. Bu ayrım var, çünkü token hızında akan bir sohbet dökümü
ölçüm ve yeniden kullanım üzerinde hücre düzeyinde denetim ister; SwiftUI'ın diffing'i bunu vermez.
Sınırı [`Features/Chat/ARCHITECTURE.md`](../../ios/Oriveo/Oriveo/Features/Chat/ARCHITECTURE.md)
belgeliyor.

**Bu dökümü üç ayrı yol günceller** ve bu bilinçlidir:

| Yol | Ne taşır | Neden |
|---|---|---|
| `@Observable AppState` | yapısal değişiklikler — bir mesaj belirir, sohbet değişir | SwiftUI'a doğal, düşük frekanslı olaylar için ucuz |
| GRDB `ValueObservation` | SQLite'tan geri okunan kalıcı durum | yazmadan sonra tek doğruluk kaynağı, yeniden başlatmayı atlatır |
| Sohbet başına Combine `PassthroughSubject` | akan metin ve akıl yürütme delta'ları | token hızında SwiftUI diffing'ini tümüyle atlar |

**Sağlayıcı desteği tek bir enum değil, dört bağımsız eksendir.** `ProviderKind` (16 durum)
*kullanıcının neyi yapılandırdığıdır*. `ProviderServiceProtocol` *çağrı yüzeyidir*. `TransportKind`
(12 durum) *gerçekte hangi ağ protokolünün konuşulduğudur* — ve **model başına, katalogdan** çözülür,
yani aynı anahtarın arkasındaki iki model birbiriyle anlaşmayabilir. `RelayKind`, kullanıcının
verdiği endpoint'leri kapsar. Yeni bir modelin yeni bir derleme olmadan çalışabilmesi, tam da bu
dördünün ayrı tutulmasından gelir.

### Bir mesaj nasıl gönderilir

```mermaid
flowchart LR
    ui["Yazma alanı"] --> build["ChatRequestSnapshot<br/>prompt · bellek · notlar · ekler"]
    build --> recipes["Yetenek reçeteleri<br/>katalogdan çözülür"]
    recipes --> encode["encodeChatBody<br/>tek ağ sınırı"]
    encode ==>|"anahtarınız"| up(["Model sağlayıcı"])
    up ==> parse["TransportStrategy<br/>+ OriveoProviderKit birleştirici"]
    parse --> cells["Akan sohbet dökümü"]
```

`BaseAPIService.encodeChatBody`, bir istek gövdesinin bayta dönüştüğü tek noktadır. Her yetenek
reçetesi, her üretim parametresi ve her özel alan buradan geçmek zorundadır; ağ biçimini on beş yerde
değil tek bir yerde test edilebilir kılan da budur.

## Bir modelin neye izni var

İstemci, bir modelin yeteneklerini adından asla tahmin etmez. Bir **yetenek çalışma zamanı** okur —
belirli bir sağlayıcı, transport ve yetenek için isteğe tam olarak hangi JSON pointer'ların
yazılacağını anlatan reçeteler kümesi. Bu reçeteler [`shared/capabilityrecipe`](shared.md) içinde
durur ve `CapabilityRecipeRequestCompiler` tarafından uygulanır.

Dönüş yolunda `CapabilityExecutionRuntime` gerçekte ne olduğunu kaydeder. Bir yeteneği *observed*
seviyesine yalnızca seçili bir üretim akış ayrıştırıcısı yükseltebilir. HTTP 200, boş olmayan bir
yanıt ve istekteki bir tool bildirimi açıkça kanıt **değildir**. Nihai durum mesaj başına saklanır;
böylece arayüz, bir denetimin istendiğini ama hiç doğrulanmadığını söyleyebilir, sessizce işe
yaramış gibi göstermez.

## Depolama

```
Application Support/Oriveo/
  active-uid                     # storage partition, "guest" by default
  users/<uid>/
    oriveo.sqlite                # conversations, messages, notes, catalog cache
    Images/  Files/              # attachment blobs, referenced by id
    session-snapshot.json        # preferences, provider list (never API keys)
```

- **GRDB üzerinden SQLite**; WAL açık, foreign key'ler açık ve her şema değişikliğini kapsayan bir
  `DatabaseMigrator` ile. Mesajlar ve notlar üzerindeki tam metin arama, trigram tokenizer'lı FTS5
  kullanır.
- **API anahtarları Keychain'de yaşar**, sağlayıcı ve bölüm anahtarlarıyla saklanır ve oturum
  anlık görüntüsü yazılmadan önce oradan temizlenir.
- **Ek blob'ları satır değil, diskteki dosyalardır**; böylece büyük bir PDF veritabanını asla
  şişirmez.

## Uygulamanın kendisi için yaptığı tek ağ çağrısı

Soğuk açılışta uygulama, `https://api.oriveoai.com` adresine kimlik doğrulamasız ve ETag koşullu iki
`GET` isteği yapar — `/api/metadata?view=lean` ve `/api/metadata/model-facts`. Bunlar herkese açık
model kataloğunu çeker: hangi modeller var, her biri neyi destekliyor, akıl yürütme denetimleri nasıl
adlandırılmış ve maliyeti ne. Ne anahtar, ne sohbet, ne de tanımlayıcı eklenir; yanıt SQLite'ta
önbelleğe alınır, böylece katalog erişilemez olduğunda uygulama önbellekteki kopyayla çalışır.

Uygulamanın kendi adına yaptığı tek istek budur. Geri kalan her şey, sizin yapılandırdığınız bir
sağlayıcıya, sizin anahtarınızla gider.

## Proje yapısı

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

## Derleme ve çalıştırma

**Xcode 26** kurulu bir Mac ve **iOS 18 veya sonrasını** çalıştıran bir cihaza ihtiyacınız var.
Ücretsiz bir Apple Developer hesabı yeterlidir; uygulama ücretli hiçbir capability kullanmaz ve boş
bir entitlements dosyasıyla gelir.

1. `ios/Oriveo/Oriveo.xcodeproj` dosyasını açın
2. `Oriveo` scheme'ini seçin
3. **Signing & Capabilities** altında kendi Team'inizi seçin
4. Xcode `ai.oriveo.community` kaydını yapamıyorsa, bundle identifier'ı ekibinizin sahip olduğu bir
   değerle değiştirin
5. iPhone'unuzu bağlayın, Geliştirici Modu'nu açın, bilgisayara güvenin ve çalıştırın

Bunun yerine Simulator için derlemek isterseniz herhangi bir iPhone simülatörünü seçip çalıştırın.
Paket bağımlılıkları, depoya işlenmiş `Package.resolved` dosyasından çözülür.

Proje dosyası, dosya sistemiyle senkron gruplar ve `objectVersion = 77` kullanır; bu yüzden daha eski
bir Xcode dosyayı açmayı reddedebilir. Proje biçimini düzenlemek yerine Xcode'u güncelleyin.

> [!NOTE]
> Uygulama target'ı, `SWIFT_APPROACHABLE_CONCURRENCY` ve
> `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` ile Swift 5 dil kipinde derlenir. Yerel
> `OriveoProviderKit` paketi `swift-tools-version: 6.1` bildirir ve Swift 6 dil kipinde derlenir.

## Bağımlılıklar

| Paket | Sürüm | Ne için |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | SQLite erişimi, migration'lar, `ValueObservation` |
| [ChatLayout](https://github.com/ekazaev/ChatLayout) | 2.4.3 | sohbet dökümünün collection view yerleşimi |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.4.1 | Markdown render'ı |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | LaTeX render'ı |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | yedek arşivleri, Office/EPUB/ODF çıkarımı |
| `OriveoProviderKit` | yerel | sağlayıcı ağ çekirdeği, macOS ile ortak |

## Testler

Xcode'dan `OriveoTests` scheme'ini çalıştırın veya depo kökünden:

```bash
xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Gerçekten sahip olduğunuz bir simülatörü yazın — `xcrun simctl list devices available` bunları
listeler.

> [!IMPORTANT]
> Test target'ı, `#filePath` konumundan yukarı doğru çıkarak `shared/` dizinini bulur ve sözleşme
> fixture'larını oradan okur. Yaklaşık 29 test paketi buna bağlıdır, dolayısıyla **testler yalnızca
> deponun tamamı elinizdeyken geçer** — tek başına `ios/` klasörünü dışarı kopyalamak işe yaramaz.

Test paketi geniş: 273 dosyada yaklaşık 2.900 test, çoğunlukla [Swift
Testing](https://github.com/swiftlang/swift-testing) ile. Sağlayıcı başına istek biçimini, kaydedilmiş
upstream SSE yeniden oynatımını, relay ve yerel motor politikasını, sohbet dökümü ölçümünü ve akış
davranışını, depolamayı ve yedekleme gidiş-dönüşlerini kapsar.

`shared/OriveoProviderKit`'in kendi test paketi vardır:

```bash
cd shared/OriveoProviderKit && swift test
```

## Yerelleştirme

On altı dil, Xcode String Catalog (`.xcstrings`) olarak saklanıyor — on katalog, yaklaşık 1.900
anahtar, kaynak dil İngilizce. Metinler, kullanıcının uygulama içi dil ayarına göre seçilen bir
`.lproj` bundle'ı üzerinden `L10n.tr(_:table:)` ile çözülür; bu yüzden dil değiştirmek uygulamayı
yeniden başlatmadan etkili olur. Arapça için sağdan sola yerleşim açıkça ele alınır.

## Katkıda bulunma

Bkz. [CONTRIBUTING.md](../../CONTRIBUTING.md). Davranış değişikliğiyle birlikte bir test ekleyin;
sağlayıcı protokolü düzeltmelerinde elle yazılmış bir mock yerine `shared/test-fixtures` altındaki
kayıtlı bir fixture'ı tercih edin ve hangi sağlayıcı ile hangi modele karşı test ettiğinizi belirtin.

## Lisans

[AGPL-3.0-or-later](../../LICENSE).
