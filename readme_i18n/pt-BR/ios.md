<div align="center">

# Oriveo para iOS

**Um cliente de chat nativo em SwiftUI para os modelos de IA que você já paga.**

<a href="../../LICENSE"><img alt="Licença AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="iOS 18 ou superior" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white">
<img alt="Feito com Swift" src="https://img.shields.io/badge/Swift-6.1_package_·_Xcode_26-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="16 idiomas de interface" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

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
**Português** ·
<a href="../ru/ios.md">Русский</a> ·
<a href="../th/ios.md">ไทย</a> ·
<a href="../tr/ios.md">Türkçe</a> ·
<a href="../vi/ios.md">Tiếng Việt</a> ·
<a href="../zh-Hans/ios.md">简体中文</a> ·
<a href="../zh-Hant/ios.md">繁體中文</a>

</sub>

</div>

---

O cliente iOS do Oriveo é um app de chat com IA no modelo BYOK. Você adiciona chaves de API que já
possui, e o app chama cada provedor diretamente do telefone. Conversas, mensagens, notas e pastas de
notas ficam em um banco SQLite no dispositivo; os blobs de anexo são arquivos ao lado dele; habilidades,
preferências, a lista de provedores e as pastas de conversas são JSON no dispositivo. As chaves de
API vão para o Keychain do iOS.

Não existe conta Oriveo: nada é enviado para nenhum lugar, e não há onde fazer login. Dois provedores
oferecem entrar com uma assinatura que você já tem em vez de colar uma chave — ChatGPT e Grok — e
esse login vai para a OpenAI e para a xAI, não para nós.

Ele faz parte do [Oriveo Community Edition](README.md) — três clientes que compartilham uma única
definição de como falar com um provedor de modelos.

## Arquitetura

```mermaid
flowchart TB
    subgraph ui ["Apresentação"]
        direction LR
        swiftui["SwiftUI<br/>NavigationStack · AppRoute"]
        uikit["Transcrição UIKit<br/>UICollectionView · ChatLayout"]
    end

    appstate["AppState · @Observable<br/>ChatManager · ProviderManager · NoteManager · SkillManager"]

    subgraph store ["No dispositivo"]
        direction LR
        grdb[("SQLite · GRDB")]
        keychain[["Keychain · chaves de API"]]
        files[("Imagens · Arquivos")]
    end

    subgraph provider ["Camada de provedor"]
        direction LR
        services["15 ProviderService<br/>o relay reaproveita o da OpenAI"]
        transports["TransportRegistry<br/>12 estratégias"]
        kit["OriveoProviderKit<br/>SSE · montagem de chunks · ocultação"]
    end

    swiftui & uikit <--> appstate
    appstate <--> grdb & keychain & files
    appstate --> services
    services --> transports --> kit
    kit ==>|"sua chave"| up["Provedor de modelos"]
```

Três coisas sobre este diagrama merecem ser ditas com clareza.

**A transcrição é UIKit, o resto é SwiftUI.** O `ChatView` embute um
`ChatListViewControllerRepresentable` em volta de uma `UICollectionView` conduzida pelo
[ChatLayout](https://github.com/ekazaev/ChatLayout). Todo o resto — navegação, configurações,
cadastro de provedor, notas, habilidades — é SwiftUI. A divisão existe porque uma transcrição em
streaming na velocidade dos tokens precisa de um controle no nível da célula sobre medição e reuso
que o diffing do SwiftUI não oferece. O
[`Features/Chat/ARCHITECTURE.md`](../../ios/Oriveo/Oriveo/Features/Chat/ARCHITECTURE.md) documenta
essa fronteira.

**Três caminhos separados atualizam essa transcrição**, de propósito:

| Caminho | Carrega | Por quê |
|---|---|---|
| `@Observable AppState` | mudanças estruturais — uma mensagem aparece, uma conversa muda | nativo do SwiftUI, barato para eventos de baixa frequência |
| GRDB `ValueObservation` | estado durável lido de volta do SQLite | uma única fonte de verdade depois de uma escrita, sobrevive a um relançamento |
| Combine `PassthroughSubject` por conversa | deltas de texto e de raciocínio em streaming | contorna completamente o diffing do SwiftUI na velocidade dos tokens |

**O suporte a provedores são quatro eixos independentes, não um enum.** `ProviderKind` (16 casos: os
quinze provedores mais o relay) é *quem o usuário configurou*. `ProviderServiceProtocol` é *a superfície de chamada*. `TransportKind`
(12 casos) é *qual protocolo de rede é de fato falado* — e ele é resolvido **por modelo, a partir do
catálogo**, então dois modelos atrás da mesma chave podem discordar. `RelayKind` cobre endpoints
fornecidos pelo usuário. Mantê-los separados é o que permite que um modelo novo funcione sem um novo
build.

### Como uma mensagem é enviada

```mermaid
flowchart LR
    ui["Compositor"] --> build["ChatRequestSnapshot<br/>prompt · memória · notas · anexos"]
    build --> recipes["Receitas de capacidade<br/>resolvidas pelo catálogo"]
    recipes --> encode["encodeChatBody<br/>a única fronteira de rede"]
    encode ==>|"sua chave"| up(["Provedor de modelos"])
    up ==> parse["TransportStrategy<br/>+ montador OriveoProviderKit"]
    parse --> cells["Transcrição em streaming"]
```

O `BaseAPIService.encodeChatBody` é a última parada antes de uma requisição compatível com OpenAI
virar bytes — doze dos dezesseis tipos passam por ele, então uma receita de capacidade, um
parâmetro de geração ou um campo personalizado é testável em um lugar só, em vez de doze. OpenAI,
Anthropic e Gemini falam os seus próprios formatos e serializam nos seus próprios serviços; cada um
desses pontos é coberto pela sua própria suíte de formato de requisição.

## O que um modelo pode fazer

O cliente nunca adivinha as capacidades de um modelo pelo nome. Ele lê um **runtime de capacidades**
— um conjunto de receitas que descrevem, para um dado provedor, transporte e capacidade, exatamente
quais JSON pointers escrever na requisição. Essas receitas ficam em
[`shared/capabilityrecipe`](../../shared/capabilityrecipe/) e são aplicadas pelo
`CapabilityRecipeRequestCompiler`.

Na volta, o `CapabilityExecutionRuntime` registra o que de fato aconteceu. Só um parser de stream de
produção selecionado pode promover uma capacidade a *observada*. Um HTTP 200, uma resposta não
vazia e uma declaração de tool na requisição explicitamente **não** são evidência. O estado final é
guardado por mensagem, para que a interface possa dizer que um controle foi pedido mas nunca
confirmado, em vez de silenciosamente dar a entender que funcionou.

## Armazenamento

```
Application Support/Oriveo/
  active-uid                     # storage partition, "guest" by default
  users/<uid>/
    oriveo.sqlite                # conversations, messages, notes and folders, catalog cache
    Images/  Files/              # attachment blobs, referenced by id
    session-snapshot.json        # preferences, provider list, folders, last used model
```

- **SQLite via GRDB** com WAL, foreign keys ligadas e um `DatabaseMigrator` cobrindo cada mudança de
  schema. A busca em texto completo sobre mensagens e notas usa FTS5 com um tokenizador de
  trigramas.
- **As chaves de API ficam no Keychain**, indexadas por provedor e partição, e são apagadas do
  snapshot de sessão antes de ele ser escrito. As habilidades são guardadas em separado, como JSON no
  `UserDefaults`.
- **Os blobs de anexo são arquivos em disco**, não linhas, então um PDF grande nunca incha o banco de
  dados.

Um backup é um ZIP `.oriveo` que contém o `data.json` mais os arquivos de imagem. A senha opcional
não criptografa o arquivo: ela criptografa apenas as chaves de API de provedor que estão dentro dele
(AES-GCM, com uma chave derivada por PBKDF2-HMAC-SHA256 em 600.000 iterações). Conversas, notas,
habilidades e preferências ficam como JSON puro no arquivo de qualquer forma, então trate um arquivo de
backup como legível por qualquer pessoa que o tenha.

## O catálogo de modelos

Na inicialização a frio, o app faz uma requisição `GET` não autenticada e condicional por ETag para
`https://api.oriveoai.com/api/metadata?view=lean`. Ela busca o catálogo público de modelos: quais
modelos existem, o que cada um suporta, como os seus controles de raciocínio se chamam e quanto
custa. Nenhuma chave, conversa ou identificador é anexado, e a resposta é cacheada em SQLite, de modo
que o app funciona a partir da cópia em cache quando o catálogo está inacessível. Um segundo
endpoint, `/api/metadata/model-facts`, só é lido depois que você entra com uma assinatura do ChatGPT
ou do Grok, para descobrir o que os modelos daquela assinatura podem fazer.

Essas são as únicas requisições que o app faz em nome próprio. Todo o resto vai para um provedor que
você configurou, com a sua chave.

Apontar o catálogo para o seu próprio host é uma **conveniência de build Debug**, resolvida em
`Oriveo/Core/Providers/BackendURLResolver.swift` nesta ordem:

1. a variável de ambiente `ORIVEO_METADATA_BASE_URL`, definida na Run action do scheme; depois
2. uma string `ORIVEO_METADATA_BASE_URL` em `ios/Oriveo/Config/Info.plist` — a chave já está lá,
   vazia, então basta preenchê-la; depois
3. `https://api.oriveoai.com`.

Duas coisas para saber. Um build Release ignora as duas e sempre usa o catálogo publicado; mudar isso
significa editar `BackendURLResolver`. E quando o bundle de testes está rodando, ou com `CI=true`, uma
sobrescrita que aponte para um endereço privado (localhost, `10/8`, `192.168/16`, `172.16/12`,
`.local`, IPv6 link-local) é ignorada, para que um host local esquecido não faça a suíte depender da
máquina em que você estiver.

## Estrutura do projeto

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

## Compilar e executar

Você precisa do **Xcode 26** e, para rodar em hardware, de um dispositivo com **iOS 18 ou superior**.
Uma conta gratuita de Apple Developer é suficiente: o arquivo de entitlements é vazio e o app não usa
nenhuma capability paga — sem push, sem iCloud, sem app groups, sem associated domains.

O Xcode 16.3 é o piso que o formato do projeto e a versão do Swift tools realmente impõem, mas o
target define `SWIFT_APPROACHABLE_CONCURRENCY` e `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, que
versões mais antigas do Xcode ignoram sem avisar. Mudar o actor isolation silenciosamente é uma
péssima forma de descobrir isso, então compile com o Xcode 26.

1. Abra `ios/Oriveo/Oriveo.xcodeproj`
2. Selecione o scheme `Oriveo`
3. Em **Signing & Capabilities**, escolha o seu próprio Team
4. Se o Xcode não conseguir registrar `ai.oriveo.community`, troque o bundle identifier por um que o
   seu time possua
5. Conecte o seu iPhone, ative o Modo de Desenvolvedor, confie no computador e rode

Para compilar para o Simulador, escolha qualquer simulador de iPhone e rode. As dependências de
pacote são resolvidas a partir do `Package.resolved` versionado.

**Em um Mac com Apple silicon** o build de iPhone também roda nativamente: escolha o destino **My Mac
(Designed for iPad)**. O Mac Catalyst não está habilitado — o projeto nunca opta por ele e o
`TARGETED_DEVICE_FAMILY` continua `1,2` —, então isto é o app iOS sob o runtime de compatibilidade do
iPad, e não um app de Mac, e caminhos que só existem no dispositivo, como a captura pela câmera, se
comportam como se comportam em um Mac.

O arquivo de projeto usa `objectVersion = 77` com grupos sincronizados com o sistema de arquivos,
então um Xcode mais antigo pode se recusar a abri-lo. Atualize o Xcode em vez de editar o formato do
projeto.

> [!NOTE]
> O target do app compila no modo de linguagem Swift 5; o pacote local `OriveoProviderKit` declara
> `swift-tools-version: 6.1` e compila no modo de linguagem Swift 6.

## Dependências

| Pacote | Versão | Usado para |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | acesso a SQLite, migrações, `ValueObservation` |
| [ChatLayout](https://github.com/ekazaev/ChatLayout) | 2.4.3 | o layout de collection view da transcrição |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.4.1 | renderização de Markdown |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | renderização de LaTeX |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | arquivos de backup, extração de Office/EPUB/ODF |
| `OriveoProviderKit` | local | o núcleo de protocolo dos provedores, em [`shared/`](shared.md) |

O `Package.resolved` também fixa as duas dependências transitivas que o swift-markdown-ui traz:
[NetworkImage](https://github.com/gonzalezreal/NetworkImage) 6.0.1 e
[swift-cmark](https://github.com/swiftlang/swift-cmark) 0.8.0. Toda dependência direta é licenciada
sob MIT e o swift-cmark é BSD-2-Clause, todas compatíveis com a AGPL-3.0-or-later.

## Testes

Rode a test action do scheme `Oriveo` (⌘U) pelo Xcode, ou, a partir da raiz do repositório:

```bash
xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Substitua por um simulador que você realmente tenha; `xcodebuild -showdestinations` com o mesmo
project e scheme lista tudo o que este checkout consegue compilar.

> [!IMPORTANT]
> O target de testes lê fixtures de contrato de `shared/` subindo a partir de `#filePath` até
> encontrar esse diretório, então **os testes só passam em um checkout completo** — copiar só `ios/`
> para fora não vai funcionar.

A suíte é grande: cerca de 2.900 casos de [Swift
Testing](https://github.com/swiftlang/swift-testing) mais 76 de XCTest, em 275 arquivos. Ela cobre o
formato da requisição por provedor, replay de SSE upstream gravado, política de relay e de engines
locais, medição da transcrição e comportamento de streaming, armazenamento e ciclos completos de
backup.

O `shared/OriveoProviderKit` tem a sua própria suíte:

```bash
cd shared/OriveoProviderKit && swift test
```

## Localização

Dezesseis idiomas, guardados como String Catalogs do Xcode (`.xcstrings`) — dez catálogos, cerca de
1.340 chaves, com o inglês como origem. Toda chave é traduzida para os dezesseis idiomas, com exceção
das poucas marcadas com `shouldTranslate: false`: o nome do produto, pontuação, esqueletos de formato
e valores de protocolo que seria errado localizar. As strings são resolvidas por `L10n.tr(_:table:)`
contra um bundle `.lproj` escolhido pela configuração de idioma dentro do app, então trocar de idioma
faz efeito sem reiniciar. O layout da direita para a esquerda em árabe é tratado explicitamente.

## Como contribuir

Veja o [CONTRIBUTING.md](../../CONTRIBUTING.md). Acrescente um teste junto com uma mudança de
comportamento; para uma correção de protocolo de provedor, prefira uma fixture gravada em
`shared/test-fixtures` a um mock escrito à mão, e diga contra qual provedor e modelo você testou.

## Licença

[AGPL-3.0-or-later](../../LICENSE).
