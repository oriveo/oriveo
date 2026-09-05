<div align="center">

# Oriveo pour iOS

**Un client de chat SwiftUI natif pour les modèles d'IA que vous payez déjà.**

<a href="../../LICENSE"><img alt="Licence AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="iOS 18 et versions ultérieures" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white">
<img alt="Construit avec Swift" src="https://img.shields.io/badge/Swift-6.1_package_·_Xcode_26-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="16 langues d'interface" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

<sub>

<a href="../../ios/README.md">English</a> ·
<a href="../ar/ios.md">العربية</a> ·
<a href="../de/ios.md">Deutsch</a> ·
<a href="../es/ios.md">Español</a> ·
**Français** ·
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

Le client iOS d'Oriveo est une app de chat IA qui fonctionne avec vos propres clés. Vous ajoutez des
clés API que vous possédez déjà, et l'app appelle chaque fournisseur directement depuis le
téléphone. Conversations, notes, dossiers, Skills et pièces jointes sont stockés sur l'appareil dans
SQLite ; les clés API vont dans le Keychain iOS. Il n'y a ni compte ni connexion.

Il fait partie d'[Oriveo Community Edition](README.md) — trois clients qui partagent une seule
définition de la façon de parler à un fournisseur de modèles.

## Architecture

```mermaid
flowchart TB
    subgraph ui ["Présentation"]
        direction LR
        swiftui["SwiftUI<br/>NavigationStack · AppRoute"]
        uikit["Fil UIKit<br/>UICollectionView · ChatLayout"]
    end

    appstate["AppState · @Observable<br/>ChatManager · ProviderManager · NoteManager · SkillManager"]

    subgraph store ["Sur l'appareil"]
        direction LR
        grdb[("SQLite · GRDB")]
        keychain[["Keychain · clés API"]]
        files[("Images · Fichiers")]
    end

    subgraph provider ["Couche fournisseur"]
        direction LR
        services["15 ProviderService"]
        transports["TransportRegistry<br/>12 stratégies"]
        kit["OriveoProviderKit<br/>SSE · assemblage de chunks · masquage"]
    end

    swiftui & uikit <--> appstate
    appstate <--> grdb & keychain & files
    appstate --> services
    services --> transports --> kit
    kit ==>|"votre clé"| up["Fournisseur de modèles"]
```

Trois choses méritent d'être dites clairement à propos de ce schéma.

**Le fil de conversation est en UIKit, le reste en SwiftUI.** `ChatView` encapsule un
`ChatListViewControllerRepresentable` autour d'une `UICollectionView` pilotée par
[ChatLayout](https://github.com/ekazaev/ChatLayout). Tout le reste — navigation, réglages,
configuration des fournisseurs, notes, Skills — est en SwiftUI. Cette séparation existe parce qu'un
fil qui streame au rythme des tokens exige, au niveau de la cellule, un contrôle sur la mesure et la
réutilisation que le diffing de SwiftUI ne donne pas.
[`Features/Chat/ARCHITECTURE.md`](../../ios/Oriveo/Oriveo/Features/Chat/ARCHITECTURE.md) documente
la frontière.

**Trois chemins distincts mettent ce fil à jour**, délibérément :

| Chemin | Transporte | Pourquoi |
|---|---|---|
| `@Observable AppState` | les changements structurels — un message apparaît, on change de conversation | natif SwiftUI, peu coûteux pour des événements peu fréquents |
| GRDB `ValueObservation` | l'état durable relu depuis SQLite | une seule source de vérité après une écriture, survit à un redémarrage |
| Combine `PassthroughSubject` par conversation | les deltas de texte et de raisonnement en streaming | contourne entièrement le diffing SwiftUI au rythme des tokens |

**La prise en charge des fournisseurs, ce sont quatre axes indépendants, pas une énumération.**
`ProviderKind` (16 cas), c'est *ce que l'utilisateur a configuré*. `ProviderServiceProtocol`, c'est
*la surface d'appel*. `TransportKind` (12 cas), c'est *le protocole réseau réellement parlé* — et il
est résolu **par modèle, depuis le catalogue**, deux modèles derrière la même clé peuvent donc
diverger. `RelayKind` couvre les endpoints fournis par l'utilisateur. C'est le fait de les garder
séparés qui permet à un nouveau modèle de fonctionner sans nouveau build.

### Comment un message est envoyé

```mermaid
flowchart LR
    ui["Composer"] --> build["ChatRequestSnapshot<br/>prompt · mémoire · notes · pièces jointes"]
    build --> recipes["Recettes de capacités<br/>résolues depuis le catalogue"]
    recipes --> encode["encodeChatBody<br/>l'unique frontière réseau"]
    encode ==>|"votre clé"| up(["Fournisseur de modèles"])
    up ==> parse["TransportStrategy<br/>+ assembleur OriveoProviderKit"]
    parse --> cells["Fil en streaming"]
```

`BaseAPIService.encodeChatBody` est le point unique où un corps de requête devient des octets.
Chaque recette de capacité, chaque paramètre de génération et chaque champ personnalisé doit passer
par là, et c'est ce qui rend le format réseau testable à un seul endroit au lieu de quinze.

## Ce qu'un modèle a le droit de faire

Le client ne devine jamais les capacités d'un modèle d'après son nom. Il lit un **runtime de
capacités** — un ensemble de recettes décrivant, pour un fournisseur, un transport et une capacité
donnés, exactement quels pointeurs JSON écrire dans la requête. Ces recettes vivent dans
[`shared/capabilityrecipe`](shared.md) et sont appliquées par `CapabilityRecipeRequestCompiler`.

Au retour, `CapabilityExecutionRuntime` enregistre ce qui s'est réellement passé. Seul un analyseur
de flux de production sélectionné peut promouvoir une capacité à l'état *observed*. Un HTTP 200, une
réponse non vide et une déclaration d'outil dans la requête ne sont explicitement **pas** des
preuves. L'état terminal est stocké par message, pour que l'interface puisse vous dire qu'un
contrôle a été demandé mais jamais confirmé, plutôt que de laisser croire en silence qu'il a
fonctionné.

## Stockage

```
Application Support/Oriveo/
  active-uid                     # storage partition, "guest" by default
  users/<uid>/
    oriveo.sqlite                # conversations, messages, notes, catalog cache
    Images/  Files/              # attachment blobs, referenced by id
    session-snapshot.json        # preferences, provider list (never API keys)
```

- **SQLite via GRDB** avec WAL, clés étrangères activées et un `DatabaseMigrator` couvrant chaque
  changement de schéma. La recherche plein texte sur les messages et les notes utilise FTS5 avec un
  tokenizer par trigrammes.
- **Les clés API vivent dans le Keychain**, indexées par fournisseur et par partition, et sont vidées
  de l'instantané de session avant son écriture.
- **Les blobs de pièces jointes sont des fichiers sur disque**, pas des lignes, de sorte qu'un gros
  PDF ne gonfle jamais la base.

## Le seul appel réseau que l'app passe pour elle-même

Au démarrage à froid, l'app émet deux requêtes `GET` non authentifiées et conditionnelles par ETag
vers `https://api.oriveoai.com` — `/api/metadata?view=lean` et `/api/metadata/model-facts`. Elles
récupèrent le catalogue public de modèles : quels modèles existent, ce que chacun prend en charge,
comment ses contrôles de raisonnement sont nommés et ce qu'il coûte. Aucune clé, aucune conversation
et aucun identifiant n'y sont attachés, et la réponse est mise en cache dans SQLite pour que l'app
fonctionne depuis la copie en cache quand le catalogue est injoignable.

C'est la seule requête que l'app passe pour son propre compte. Tout le reste va vers un fournisseur
que vous avez configuré, avec votre clé.

## Structure du projet

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

## Compiler et lancer

Il vous faut un Mac avec **Xcode 26** et un appareil sous **iOS 18 ou plus récent**. Un compte Apple
Developer gratuit suffit ; l'app n'utilise aucune capability payante et livre un fichier
d'entitlements vide.

1. Ouvrez `ios/Oriveo/Oriveo.xcodeproj`
2. Sélectionnez le schéma `Oriveo`
3. Sous **Signing & Capabilities**, choisissez votre propre Team
4. Si Xcode ne peut pas enregistrer `ai.oriveo.community`, changez le bundle identifier pour un que
   votre Team possède
5. Branchez votre iPhone, activez le mode développeur, faites confiance à l'ordinateur, et lancez

Pour compiler vers le simulateur à la place, choisissez n'importe quel simulateur d'iPhone et
lancez. Les dépendances de paquets sont résolues depuis le `Package.resolved` versionné.

Le fichier de projet utilise `objectVersion = 77` avec des groupes synchronisés au système de
fichiers ; un Xcode plus ancien peut donc refuser de l'ouvrir. Mettez Xcode à jour plutôt que de
modifier le format du projet.

> [!NOTE]
> La cible de l'app compile en mode langage Swift 5 avec `SWIFT_APPROACHABLE_CONCURRENCY` et
> `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Le paquet local `OriveoProviderKit` déclare
> `swift-tools-version: 6.1` et compile en mode langage Swift 6.

## Dépendances

| Paquet | Version | Sert à |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | accès SQLite, migrations, `ValueObservation` |
| [ChatLayout](https://github.com/ekazaev/ChatLayout) | 2.4.3 | la mise en page collection-view du fil |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.4.1 | rendu Markdown |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | rendu LaTeX |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | archives de sauvegarde, extraction Office/EPUB/ODF |
| `OriveoProviderKit` | local | le noyau de protocole fournisseur, partagé avec macOS |

## Tests

Lancez le schéma `OriveoTests` depuis Xcode, ou depuis la racine du dépôt :

```bash
xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Remplacez par un simulateur que vous avez réellement — `xcrun simctl list devices available` les
liste.

> [!IMPORTANT]
> La cible de test lit les fixtures de contrat depuis `shared/` en remontant depuis `#filePath`
> jusqu'à trouver ce répertoire. Environ 29 suites en dépendent, donc **les tests ne passent que
> dans un checkout complet** — copier `ios/` tout seul ne marchera pas.

La suite est grosse : environ 2 900 tests répartis sur 273 fichiers, surtout en [Swift
Testing](https://github.com/swiftlang/swift-testing). Elle couvre la forme des requêtes par
fournisseur, le rejeu de flux SSE amont enregistrés, la politique des relais et des moteurs locaux,
la mesure du fil et son comportement en streaming, le stockage et les allers-retours de sauvegarde.

`shared/OriveoProviderKit` a sa propre suite :

```bash
cd shared/OriveoProviderKit && swift test
```

## Localisation

Seize langues, stockées sous forme de String Catalogs Xcode (`.xcstrings`) — dix catalogues, environ
1 900 clés, l'anglais comme source. Les chaînes sont résolues via `L10n.tr(_:table:)` contre un
bundle `.lproj` choisi d'après le réglage de langue interne à l'app, si bien que changer de langue
prend effet sans relancer. La mise en page droite-à-gauche pour l'arabe est traitée explicitement.

## Contribuer

Voir [CONTRIBUTING.md](../../CONTRIBUTING.md). Ajoutez un test avec tout changement de comportement ;
pour une correction de protocole fournisseur, préférez une fixture enregistrée sous
`shared/test-fixtures` à un mock écrit à la main, et précisez contre quel fournisseur et quel modèle
vous avez testé.

## Licence

[AGPL-3.0-or-later](../../LICENSE).
