<div align="center">

# Oriveo für iOS

**Ein nativer SwiftUI-Chat-Client für die KI-Modelle, für die du ohnehin schon zahlst.**

<a href="../../LICENSE"><img alt="Lizenz AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="iOS 18 und neuer" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white">
<img alt="Mit Swift gebaut" src="https://img.shields.io/badge/Swift-6.1_package_·_Xcode_26-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="16 Oberflächensprachen" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

<sub>

<a href="../../ios/README.md">English</a> ·
<a href="../ar/ios.md">العربية</a> ·
**Deutsch** ·
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
<a href="../zh-Hant/ios.md">繁體中文</a>

</sub>

</div>

---

Der Oriveo-iOS-Client ist eine KI-Chat-App, die mit deinem eigenen Key arbeitet. Du hinterlegst
API-Keys, die dir schon gehören, und die App ruft jeden Anbieter direkt vom Telefon aus auf.
Unterhaltungen, Nachrichten, Notizen und Notizordner liegen in einer SQLite-Datenbank auf dem Gerät;
Anhang-Blobs sind Dateien daneben; Fähigkeiten, Einstellungen, die Anbieterliste und Unterhaltungsordner
sind JSON auf dem Gerät. API-Keys gehen in die iOS Keychain.

Es gibt kein Oriveo-Konto: nichts wird hochgeladen, und es gibt nichts, wo man sich anmelden müsste.
Zwei Anbieter bieten allerdings an, sich statt mit einem eingefügten Key mit einem Abo anzumelden,
das du schon hast – ChatGPT und Grok –, und diese Anmeldung geht an OpenAI und xAI, nicht an uns.

Er ist Teil der [Oriveo Community Edition](README.md) – drei Clients, die sich eine Definition
davon teilen, wie man mit einem Modellanbieter spricht.

## Architektur

```mermaid
flowchart TB
    subgraph ui ["Darstellung"]
        direction LR
        swiftui["SwiftUI<br/>NavigationStack · AppRoute"]
        uikit["UIKit-Verlauf<br/>UICollectionView · ChatLayout"]
    end

    appstate["AppState · @Observable<br/>ChatManager · ProviderManager · NoteManager · SkillManager"]

    subgraph store ["Auf dem Gerät"]
        direction LR
        grdb[("SQLite · GRDB")]
        keychain[["Keychain · API-Keys"]]
        files[("Bilder · Dateien")]
    end

    subgraph provider ["Anbieter-Schicht"]
        direction LR
        services["15 ProviderService<br/>Relay nutzt den von OpenAI"]
        transports["TransportRegistry<br/>12 Strategien"]
        kit["OriveoProviderKit<br/>SSE · Chunk-Aufbau · Schwärzung"]
    end

    swiftui & uikit <--> appstate
    appstate <--> grdb & keychain & files
    appstate --> services
    services --> transports --> kit
    kit ==>|"dein Key"| up["Modellanbieter"]
```

Drei Dinge an diesem Diagramm gehören klar gesagt.

**Der Verlauf ist UIKit, alles andere ist SwiftUI.** `ChatView` bettet ein
`ChatListViewControllerRepresentable` um eine `UICollectionView` ein, angetrieben von
[ChatLayout](https://github.com/ekazaev/ChatLayout). Alles andere – Navigation, Einstellungen,
Anbieter-Einrichtung, Notizen, Fähigkeiten – ist SwiftUI. Die Trennung gibt es, weil ein Verlauf, der im
Token-Takt streamt, Kontrolle über Vermessung und Wiederverwendung auf Zellebene braucht, die
SwiftUIs Diffing nicht hergibt.
[`Features/Chat/ARCHITECTURE.md`](../../ios/Oriveo/Oriveo/Features/Chat/ARCHITECTURE.md)
dokumentiert die Grenze.

**Drei getrennte Pfade aktualisieren diesen Verlauf**, und das mit Absicht:

| Pfad | Trägt | Warum |
|---|---|---|
| `@Observable AppState` | strukturelle Änderungen – eine Nachricht erscheint, eine Unterhaltung wechselt | SwiftUI-nativ, günstig bei seltenen Ereignissen |
| GRDB `ValueObservation` | dauerhafter Zustand, aus SQLite zurückgelesen | eine Quelle der Wahrheit nach einem Schreibvorgang, übersteht einen Neustart |
| Combine `PassthroughSubject` pro Unterhaltung | Text- und Reasoning-Deltas im Stream | umgeht SwiftUIs Diffing im Token-Takt komplett |

**Anbieter-Unterstützung besteht aus vier unabhängigen Achsen, nicht aus einem Enum.**
`ProviderKind` (16 Fälle: die fünfzehn Anbieter plus Relay) ist *wen der Nutzer eingerichtet
hat*. `ProviderServiceProtocol` ist *die
Aufruffläche*. `TransportKind` (12 Fälle) ist *welches Wire-Protokoll tatsächlich gesprochen wird* –
und das wird **pro Modell aus dem Katalog** aufgelöst, zwei Modelle hinter demselben Key können sich
also unterscheiden. `RelayKind` deckt selbst hinterlegte Endpunkte ab. Genau diese Trennung sorgt
dafür, dass ein neues Modell ohne neuen Build funktioniert.

### Wie eine Nachricht verschickt wird

```mermaid
flowchart LR
    ui["Composer"] --> build["ChatRequestSnapshot<br/>Prompt · Memory · Notizen · Anhänge"]
    build --> recipes["Capability-Rezepte<br/>aus dem Katalog aufgelöst"]
    recipes --> encode["encodeChatBody<br/>die eine Wire-Grenze"]
    encode ==>|"dein Key"| up(["Modellanbieter"])
    up ==> parse["TransportStrategy<br/>+ OriveoProviderKit-Assembler"]
    parse --> cells["Streaming-Verlauf"]
```

`BaseAPIService.encodeChatBody` ist die letzte Station, bevor ein OpenAI-kompatibler Request zu
Bytes wird – zwölf der sechzehn Fälle laufen da hindurch, ein Capability-Rezept, ein
Generierungsparameter oder ein eigenes Feld ist damit an einer Stelle testbar statt an zwölf. OpenAI,
Anthropic und Gemini sprechen ihre eigenen Formen und serialisieren in ihren eigenen Services; jede
dieser Stellen ist von ihrer eigenen Request-Form-Suite abgedeckt.

## Was ein Modell darf

Der Client rät die Fähigkeiten eines Modells nie aus seinem Namen. Er liest eine **Capability
Runtime** – eine Menge Rezepte, die für einen bestimmten Anbieter, Transport und eine Fähigkeit
genau beschreiben, welche JSON-Pointer in den Request geschrieben werden. Diese Rezepte liegen in
[`shared/capabilityrecipe`](../../shared/capabilityrecipe/) und werden von
`CapabilityRecipeRequestCompiler` angewendet.

Auf dem Rückweg hält `CapabilityExecutionRuntime` fest, was tatsächlich passiert ist. Nur ein
ausgewählter produktiver Stream-Parser darf eine Fähigkeit auf *observed* heben. Ein HTTP 200, eine
nicht leere Antwort und eine Tool-Deklaration im Request sind ausdrücklich **kein** Beleg. Der
Endzustand wird pro Nachricht gespeichert, damit die UI dir sagen kann, dass eine Steuerung
angefragt, aber nie bestätigt wurde, statt stillschweigend zu suggerieren, sie habe funktioniert.

## Speicherung

```
Application Support/Oriveo/
  active-uid                     # storage partition, "guest" by default
  users/<uid>/
    oriveo.sqlite                # conversations, messages, notes and folders, catalog cache
    Images/  Files/              # attachment blobs, referenced by id
    session-snapshot.json        # preferences, provider list, folders, last used model
```

- **SQLite über GRDB** mit WAL, aktivierten Fremdschlüsseln und einem `DatabaseMigrator`, der jede
  Schema-Änderung abdeckt. Die Volltextsuche über Nachrichten und Notizen nutzt FTS5 mit einem
  Trigramm-Tokenizer.
- **API-Keys liegen in der Keychain**, geschlüsselt nach Anbieter und Partition, und werden aus dem
  Session-Snapshot geleert, bevor er geschrieben wird. Fähigkeiten werden separat als JSON in
  `UserDefaults` gespeichert.
- **Anhang-Blobs sind Dateien auf der Platte**, keine Zeilen, damit ein großes PDF die Datenbank nie
  aufbläht.

Ein Backup ist ein `.oriveo`-ZIP mit `data.json` und den Bilddateien. Das optionale Passwort
verschlüsselt nicht das Archiv: es verschlüsselt allein die Anbieter-API-Keys darin (AES-GCM, mit
einem Schlüssel, den PBKDF2-HMAC-SHA256 über 600.000 Iterationen ableitet). Unterhaltungen, Notizen,
Fähigkeiten und Einstellungen liegen so oder so als reines JSON im Archiv – behandle eine Backup-Datei
also als lesbar für jeden, der sie hat.

## Der Modellkatalog

Beim Kaltstart setzt die App einen nicht authentifizierten, ETag-konditionalen `GET` an
`https://api.oriveoai.com/api/metadata?view=lean` ab. Er holt den öffentlichen Modellkatalog: welche
Modelle es gibt, was jedes davon unterstützt, wie seine Reasoning-Steuerungen heißen und was es
kostet. Weder Key noch Unterhaltung noch Kennung hängen daran, und die Antwort wird in SQLite
zwischengespeichert, sodass die App aus der Kopie weiterarbeitet, wenn der Katalog nicht erreichbar
ist. Einen zweiten Endpunkt, `/api/metadata/model-facts`, liest sie erst, nachdem du dich mit einem
ChatGPT- oder Grok-Abo angemeldet hast, um zu erfahren, was die Modelle dieses Abos können.

Das sind die einzigen Requests, die die App von sich aus stellt. Alles andere geht an einen
Anbieter, den du eingerichtet hast, mit deinem Key.

Den Katalog auf deinen eigenen Host zu richten ist eine **Bequemlichkeit für Debug-Builds**,
aufgelöst in `Oriveo/Core/Providers/BackendURLResolver.swift` in dieser Reihenfolge:

1. die Umgebungsvariable `ORIVEO_METADATA_BASE_URL`, gesetzt in der Run-Action des Schemas; dann
2. ein String `ORIVEO_METADATA_BASE_URL` in `ios/Oriveo/Config/Info.plist` – der Schlüssel ist schon
   da und leer, ihn auszufüllen genügt also; dann
3. `https://api.oriveoai.com`.

Zwei Dinge dazu. Ein Release-Build ignoriert beides und nimmt immer den veröffentlichten Katalog; das
zu ändern heißt, `BackendURLResolver` anzupassen. Und wenn das Test-Bundle läuft oder `CI=true`
gesetzt ist, wird ein Override auf eine private Adresse (localhost, `10/8`, `192.168/16`,
`172.16/12`, `.local`, Link-Local-IPv6) ignoriert, damit ein übrig gebliebener lokaler Host die
Suite nicht von dem Rechner abhängig macht, an dem du gerade sitzt.

## Projektaufbau

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

## Bauen und starten

Du brauchst **Xcode 26**, und für den Lauf auf echter Hardware ein Gerät mit **iOS 18 oder neuer**.
Ein kostenloser Apple-Developer-Account genügt: die Entitlements-Datei ist leer und die App nutzt
keine kostenpflichtige Capability – kein Push, kein iCloud, keine App Groups, keine Associated
Domains.

Xcode 16.3 ist die Untergrenze, die Projektformat und Swift-Tools-Version tatsächlich erzwingen, aber
das Target setzt `SWIFT_APPROACHABLE_CONCURRENCY` und `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
was ältere Xcode-Versionen ignorieren, ohne es zu sagen. Eine stillschweigend veränderte
Actor-Isolation ist eine schlechte Art, das herauszufinden – bau also mit Xcode 26.

1. Öffne `ios/Oriveo/Oriveo.xcodeproj`
2. Wähle das Schema `Oriveo`
3. Wähle unter **Signing & Capabilities** dein eigenes Team
4. Kann Xcode `ai.oriveo.community` nicht registrieren, ändere den Bundle Identifier auf einen, der
   deinem Team gehört
5. Schließe dein iPhone an, aktiviere den Entwicklermodus, vertraue dem Rechner und starte

Für den Simulator wählst du stattdessen einen beliebigen iPhone-Simulator und startest.
Paketabhängigkeiten werden aus der eingecheckten `Package.resolved` aufgelöst.

**Auf einem Mac mit Apple Silicon** läuft der iPhone-Build auch nativ: wähle das Ziel **My Mac
(Designed for iPad)**. Mac Catalyst ist nicht aktiviert – das Projekt schaltet es nie ein und
`TARGETED_DEVICE_FAMILY` bleibt `1,2` –, das ist also die iOS-App unter der
iPad-Kompatibilitätslaufzeit und keine Mac-App, und Pfade, die es nur auf dem Gerät gibt, etwa die
Kameraaufnahme, verhalten sich so, wie sie sich auf einem Mac verhalten.

Die Projektdatei nutzt `objectVersion = 77` mit dateisystemsynchronisierten Gruppen, ein älteres
Xcode kann sich also weigern, sie zu öffnen. Aktualisiere Xcode, statt am Projektformat zu
schrauben.

> [!NOTE]
> Das App-Target kompiliert im Swift-5-Sprachmodus; das lokale Paket `OriveoProviderKit` deklariert
> `swift-tools-version: 6.1` und baut im Swift-6-Sprachmodus.

## Abhängigkeiten

| Paket | Version | Wofür |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | SQLite-Zugriff, Migrationen, `ValueObservation` |
| [ChatLayout](https://github.com/ekazaev/ChatLayout) | 2.4.3 | das Collection-View-Layout des Verlaufs |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.4.1 | Markdown-Rendering |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | LaTeX-Rendering |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | Backup-Archive, Office-/EPUB-/ODF-Extraktion |
| `OriveoProviderKit` | lokal | der Provider-Wire-Kernel, in [`shared/`](shared.md) |

`Package.resolved` pinnt auch die zwei transitiven Abhängigkeiten, die swift-markdown-ui mitbringt:
[NetworkImage](https://github.com/gonzalezreal/NetworkImage) 6.0.1 und
[swift-cmark](https://github.com/swiftlang/swift-cmark) 0.8.0. Jede direkte Abhängigkeit steht unter
MIT, swift-cmark unter BSD-2-Clause, alles mit AGPL-3.0-or-later vereinbar.

## Tests

Führe in Xcode die Test-Action des Schemas `Oriveo` aus (⌘U), oder aus dem Wurzelverzeichnis des
Repositorys:

```bash
xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Setz einen Simulator ein, den du tatsächlich hast; `xcodebuild -showdestinations` mit demselben
Projekt und Schema listet alles auf, wofür dieses Checkout bauen kann.

> [!IMPORTANT]
> Das Test-Target liest Kontrakt-Fixtures aus `shared/`, indem es von `#filePath` aus nach oben
> läuft, bis es dieses Verzeichnis findet, **die Tests laufen also nur in einem vollständigen
> Checkout durch** – `ios/` allein herauszukopieren funktioniert nicht.

Die Suite ist groß: rund 2.900 Fälle in [Swift
Testing](https://github.com/swiftlang/swift-testing) plus 76 in XCTest, über 275 Dateien. Sie deckt
die Request-Form pro Anbieter,
aufgezeichnetes Upstream-SSE-Replay, Relay- und Local-Engine-Policy, Vermessung und
Streaming-Verhalten des Verlaufs, Speicherung und Backup-Rundläufe ab.

`shared/OriveoProviderKit` hat eine eigene Suite:

```bash
cd shared/OriveoProviderKit && swift test
```

## Lokalisierung

Sechzehn Sprachen, abgelegt als Xcode String Catalogs (`.xcstrings`) – zehn Kataloge, rund 1.340
Keys, Englisch als Quelle. Jeder Key ist in alle sechzehn übersetzt, bis auf die wenigen mit
`shouldTranslate: false`: den Produktnamen, Satzzeichen, Formatgerüste und Protokollwerte, die zu
lokalisieren falsch wäre. Strings werden über `L10n.tr(_:table:)` gegen ein `.lproj`-Bundle
aufgelöst, das aus der In-App-Spracheinstellung gewählt wird, ein Sprachwechsel wirkt also ohne
Neustart. Rechts-nach-links-Layout für Arabisch wird ausdrücklich behandelt.

## Mitwirken

Siehe [CONTRIBUTING.md](../../CONTRIBUTING.md). Leg zu einer Verhaltensänderung einen Test dazu; bei
einer Korrektur am Anbieter-Protokoll nimm lieber ein aufgezeichnetes Fixture unter
`shared/test-fixtures` als einen handgeschriebenen Mock, und schreib dazu, gegen welchen Anbieter
und welches Modell du getestet hast.

## Lizenz

[AGPL-3.0-or-later](../../LICENSE).
