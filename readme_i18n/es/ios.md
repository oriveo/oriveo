<div align="center">

# Oriveo para iOS

**Un cliente de chat nativo en SwiftUI para los modelos de IA que ya pagas.**

<a href="../../LICENSE"><img alt="Licencia AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="iOS 18 y posteriores" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white">
<img alt="Construido con Swift" src="https://img.shields.io/badge/Swift-6.1_package_·_Xcode_26-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="16 idiomas de interfaz" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

<sub>

<a href="../../ios/README.md">English</a> ·
<a href="../ar/ios.md">العربية</a> ·
<a href="../de/ios.md">Deutsch</a> ·
**Español** ·
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

El cliente de iOS de Oriveo es una app de chat de IA que funciona con tus propias claves. Agregas
claves de API que ya tienes, y la app llama a cada proveedor directamente desde el teléfono. Las
conversaciones, los mensajes, las notas y las carpetas de notas viven en una base de datos SQLite en
el dispositivo; los blobs de los adjuntos son archivos junto a ella; los Skills, las preferencias, la
lista de proveedores y las carpetas de conversaciones son JSON en el dispositivo. Las claves de API
van al Keychain de iOS.

No hay cuenta de Oriveo: no se sube nada, y no hay dónde iniciar sesión. Sí hay dos proveedores que
ofrecen iniciar sesión con una suscripción que ya tienes en lugar de pegar una clave —ChatGPT y
Grok— y ese inicio de sesión va a OpenAI y a xAI, no a nosotros.

Forma parte de [Oriveo Community Edition](README.md): tres clientes que comparten una sola definición
de cómo hablar con un proveedor de modelos.

## Arquitectura

```mermaid
flowchart TB
    subgraph ui ["Presentación"]
        direction LR
        swiftui["SwiftUI<br/>NavigationStack · AppRoute"]
        uikit["Hilo en UIKit<br/>UICollectionView · ChatLayout"]
    end

    appstate["AppState · @Observable<br/>ChatManager · ProviderManager · NoteManager · SkillManager"]

    subgraph store ["En el dispositivo"]
        direction LR
        grdb[("SQLite · GRDB")]
        keychain[["Keychain · claves API"]]
        files[("Imágenes · Archivos")]
    end

    subgraph provider ["Capa de proveedor"]
        direction LR
        services["15 ProviderService<br/>Relay reutiliza el de OpenAI"]
        transports["TransportRegistry<br/>12 estrategias"]
        kit["OriveoProviderKit<br/>SSE · ensamblado de chunks · ocultamiento"]
    end

    swiftui & uikit <--> appstate
    appstate <--> grdb & keychain & files
    appstate --> services
    services --> transports --> kit
    kit ==>|"tu clave"| up["Proveedor de modelos"]
```

Hay tres cosas de este diagrama que conviene decir sin rodeos.

**El hilo de la conversación es UIKit, el resto es SwiftUI.** `ChatView` incrusta un
`ChatListViewControllerRepresentable` alrededor de una `UICollectionView` impulsada por
[ChatLayout](https://github.com/ekazaev/ChatLayout). Todo lo demás —navegación, ajustes,
configuración de proveedores, notas, Skills— es SwiftUI. La división existe porque un hilo que
transmite al ritmo de los tokens necesita control a nivel de celda sobre la medición y la
reutilización que el diffing de SwiftUI no da.
[`Features/Chat/ARCHITECTURE.md`](../../ios/Oriveo/Oriveo/Features/Chat/ARCHITECTURE.md) documenta
la frontera.

**Tres rutas independientes actualizan ese hilo**, a propósito:

| Ruta | Transporta | Por qué |
|---|---|---|
| `@Observable AppState` | cambios estructurales: aparece un mensaje, se cambia de conversación | nativo de SwiftUI, barato para eventos de baja frecuencia |
| GRDB `ValueObservation` | estado duradero releído desde SQLite | una sola fuente de verdad tras una escritura, sobrevive a un reinicio |
| Combine `PassthroughSubject` por conversación | deltas de texto y de razonamiento en streaming | evita por completo el diffing de SwiftUI al ritmo de los tokens |

**El soporte de proveedores son cuatro ejes independientes, no un solo enum.** `ProviderKind` (16
casos: los quince proveedores más relay) es *lo que configuró el usuario*. `ProviderServiceProtocol`
es *la superficie de llamada*. `TransportKind` (12 casos) es *qué protocolo de red se habla
realmente*, y se resuelve **por modelo, desde el catálogo**, así que dos modelos detrás de la misma
clave pueden no coincidir. `RelayKind` cubre los endpoints que aporta el usuario. Mantenerlos
separados es justo lo que permite que un modelo nuevo funcione sin una build nueva.

### Cómo se envía un mensaje

```mermaid
flowchart LR
    ui["Composer"] --> build["ChatRequestSnapshot<br/>prompt · memoria · notas · adjuntos"]
    build --> recipes["Recetas de capacidad<br/>resueltas desde el catálogo"]
    recipes --> encode["encodeChatBody<br/>la única frontera de red"]
    encode ==>|"tu clave"| up(["Proveedor de modelos"])
    up ==> parse["TransportStrategy<br/>+ ensamblador de OriveoProviderKit"]
    parse --> cells["Hilo en streaming"]
```

`BaseAPIService.encodeChatBody` es la última parada antes de que una solicitud compatible con OpenAI
se convierta en bytes: doce de los dieciséis casos pasan por ahí, así que una receta de
capacidad, un parámetro de generación o un campo personalizado es comprobable en un solo lugar en vez
de en doce. OpenAI, Anthropic y Gemini hablan sus propias formas y serializan en sus propios
servicios; cada uno de esos puntos está cubierto por su propia suite de forma de solicitud.

## Qué puede hacer un modelo

El cliente nunca adivina las capacidades de un modelo a partir de su nombre. Lee un **runtime de
capacidades**: un conjunto de recetas que describen, para un proveedor, un transporte y una capacidad
dados, exactamente qué punteros JSON escribir en la solicitud. Esas recetas viven en
[`shared/capabilityrecipe`](../../shared/capabilityrecipe/) y las aplica
`CapabilityRecipeRequestCompiler`.

De vuelta, `CapabilityExecutionRuntime` registra lo que realmente pasó. Solo un analizador de flujo
de producción seleccionado puede promover una capacidad a *observed*. Un HTTP 200, una respuesta no
vacía y una declaración de herramienta en la solicitud explícitamente **no** son evidencia. El estado
final se guarda por mensaje, así que la interfaz puede decirte que un control se solicitó pero nunca
se confirmó, en vez de dar a entender en silencio que funcionó.

## Almacenamiento

```
Application Support/Oriveo/
  active-uid                     # storage partition, "guest" by default
  users/<uid>/
    oriveo.sqlite                # conversations, messages, notes and folders, catalog cache
    Images/  Files/              # attachment blobs, referenced by id
    session-snapshot.json        # preferences, provider list, folders, last used model
```

- **SQLite a través de GRDB** con WAL, claves foráneas activadas y un `DatabaseMigrator` que cubre
  cada cambio de esquema. La búsqueda de texto completo sobre mensajes y notas usa FTS5 con un
  tokenizador de trigramas.
- **Las claves de API viven en el Keychain**, indexadas por proveedor y partición, y se vacían del
  snapshot de sesión antes de escribirlo. Los Skills se guardan por separado como JSON en
  `UserDefaults`.
- **Los blobs de los adjuntos son archivos en disco**, no filas, así que un PDF grande nunca infla la
  base de datos.

Una copia de seguridad es un ZIP `.oriveo` que contiene `data.json` más los archivos de imagen. La
contraseña opcional no cifra el archivo comprimido: cifra solo las claves de API de proveedor que hay
dentro (AES-GCM, con una clave derivada por PBKDF2-HMAC-SHA256 con 600.000 iteraciones). Las
conversaciones, las notas, los Skills y las preferencias quedan como JSON en claro dentro del archivo
en cualquier caso, así que trata un archivo de copia de seguridad como legible por cualquiera que lo
tenga.

## Las solicitudes que la app hace por sí misma

En el arranque en frío la app emite una solicitud `GET` sin autenticar y condicional por ETag a
`https://api.oriveoai.com/api/metadata?view=lean`. Trae el catálogo público de modelos: qué modelos
existen, qué admite cada uno, cómo se llaman sus controles de razonamiento y cuánto cuesta. No lleva
clave, ni conversación, ni identificador, y la respuesta se guarda en caché en SQLite para que la app
funcione desde la copia en caché cuando el catálogo no está accesible. Un segundo endpoint,
`/api/metadata/model-facts`, se lee solo después de que inicies sesión con una suscripción de ChatGPT
o Grok, para saber qué pueden hacer los modelos de esa suscripción.

Estas son las únicas solicitudes que la app hace por cuenta propia. Todo lo demás va a un proveedor
que configuraste tú, con tu clave.

Apuntar el catálogo a tu propio host es una **comodidad de las builds Debug**, resuelta en
`Oriveo/Core/Providers/BackendURLResolver.swift` en este orden:

1. la variable de entorno `ORIVEO_METADATA_BASE_URL`, definida en la acción Run del esquema; luego
2. una cadena `ORIVEO_METADATA_BASE_URL` en `ios/Oriveo/Config/Info.plist`: la clave ya está ahí y
   vacía, así que basta con rellenarla; luego
3. `https://api.oriveoai.com`.

Dos cosas que conviene saber. Una build Release ignora ambas y siempre usa el catálogo publicado;
cambiar eso implica editar `BackendURLResolver`. Y cuando se está ejecutando el bundle de pruebas, o
con `CI=true`, se ignora una redefinición que apunte a una dirección privada (localhost, `10/8`,
`192.168/16`, `172.16/12`, `.local`, IPv6 link-local), de modo que un host local olvidado no pueda
hacer que la suite dependa de la máquina en la que estés sentado.

## Estructura del proyecto

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

## Compilar y ejecutar

Necesitas **Xcode 26** y, para ejecutar en hardware, un dispositivo con **iOS 18 o posterior**. Basta
con una cuenta gratuita de Apple Developer: el archivo de entitlements está vacío y la app no usa
ninguna capability de pago (sin push, sin iCloud, sin app groups, sin associated domains).

Xcode 16.3 es el mínimo que realmente imponen el formato del proyecto y la versión de las Swift
tools, pero el target define `SWIFT_APPROACHABLE_CONCURRENCY` y
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, que las versiones antiguas de Xcode ignoran sin decirlo.
Cambiar el aislamiento de actores en silencio es una mala forma de enterarse, así que compila con
Xcode 26.

1. Abre `ios/Oriveo/Oriveo.xcodeproj`
2. Selecciona el esquema `Oriveo`
3. En **Signing & Capabilities**, elige tu propio Team
4. Si Xcode no puede registrar `ai.oriveo.community`, cambia el bundle identifier por uno que
   pertenezca a tu Team
5. Conecta tu iPhone, activa el modo de desarrollador, confía en la computadora y ejecuta

Para compilar para el simulador, elige cualquier simulador de iPhone y ejecuta. Las dependencias de
paquetes se resuelven desde el `Package.resolved` versionado.

**En una Mac con Apple Silicon** la build de iPhone también corre de forma nativa: elige el destino
**My Mac (Designed for iPad)**. Mac Catalyst está deliberadamente desactivado
(`SUPPORTS_MACCATALYST = NO`), así que esto es la app de iOS bajo el runtime de compatibilidad de
iPad y no una app de Mac: las rutas que solo existen en el dispositivo, como la captura con la
cámara, se comportan como se comportan en una Mac.

El archivo del proyecto usa `objectVersion = 77` con grupos sincronizados con el sistema de archivos,
así que una versión antigua de Xcode puede negarse a abrirlo. Actualiza Xcode en vez de editar el
formato del proyecto.

> [!NOTE]
> El target de la app compila en modo de lenguaje Swift 5; el paquete local `OriveoProviderKit`
> declara `swift-tools-version: 6.1` y compila en modo de lenguaje Swift 6.

## Dependencias

| Paquete | Versión | Para qué sirve |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.11.1 | acceso a SQLite, migraciones, `ValueObservation` |
| [ChatLayout](https://github.com/ekazaev/ChatLayout) | 2.4.3 | el layout de collection view del hilo |
| [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) | 2.4.1 | renderizado de Markdown |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | renderizado de LaTeX |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.20 | archivos de copia de seguridad, extracción de Office/EPUB/ODF |
| `OriveoProviderKit` | local | el núcleo de protocolo de proveedores, en [`shared/`](shared.md) |

`Package.resolved` también fija las dos dependencias transitivas que trae swift-markdown-ui:
[NetworkImage](https://github.com/gonzalezreal/NetworkImage) 6.0.1 y
[swift-cmark](https://github.com/swiftlang/swift-cmark) 0.8.0. Todas las dependencias directas están
bajo licencia MIT y swift-cmark bajo BSD-2-Clause, todas compatibles con AGPL-3.0-or-later.

## Pruebas

Ejecuta la acción de pruebas del esquema `Oriveo` (⌘U) en Xcode, o desde la raíz del repositorio:

```bash
xcodebuild test -project ios/Oriveo/Oriveo.xcodeproj -scheme Oriveo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Sustituye por un simulador que realmente tengas; `xcodebuild -showdestinations` con el mismo
proyecto y esquema lista todo aquello para lo que este checkout puede compilar.

> [!IMPORTANT]
> El target de pruebas lee fixtures de contrato desde `shared/` subiendo desde `#filePath` hasta
> encontrar ese directorio, así que **las pruebas solo pasan en un checkout completo**: copiar `ios/`
> por su cuenta no funcionará.

La suite es grande: unos 2.900 casos de [Swift
Testing](https://github.com/swiftlang/swift-testing) más 76 de XCTest, repartidos en 274 archivos.
Cubre la forma de la solicitud por proveedor,
la reproducción de flujos SSE grabados del upstream, la política de relay y de motores locales, la
medición del hilo y su comportamiento en streaming, el almacenamiento y los ciclos completos de
copia de seguridad.

`shared/OriveoProviderKit` tiene su propia suite:

```bash
cd shared/OriveoProviderKit && swift test
```

## Localización

Dieciséis idiomas, guardados como String Catalogs de Xcode (`.xcstrings`): diez catálogos, unas 1.340
claves, con el inglés como fuente. Todas las claves están traducidas a los dieciséis idiomas, salvo
las pocas marcadas con `shouldTranslate: false`: el nombre del producto, la puntuación, los esqueletos
de formato y los valores de protocolo que estaría mal localizar. Las cadenas se resuelven mediante
`L10n.tr(_:table:)` contra un bundle `.lproj` elegido según el ajuste de idioma dentro de la app, así
que cambiar de idioma surte efecto sin reiniciar. El diseño de derecha a izquierda para el árabe se
maneja explícitamente.

## Contribuir

Mira [CONTRIBUTING.md](../../CONTRIBUTING.md). Agrega una prueba junto con cada cambio de
comportamiento; para una corrección de protocolo de proveedor, prefiere un fixture grabado en
`shared/test-fixtures` antes que un mock escrito a mano, y di contra qué proveedor y qué modelo
probaste.

## Licencia

[AGPL-3.0-or-later](../../LICENSE).
