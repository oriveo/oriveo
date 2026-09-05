<div align="center">

<img src="../../docs/assets/logo.png" width="104" height="104" alt="">

# Oriveo

**Todos los modelos, una sola app.**

Chat de IA de código abierto con tus propias claves, para iOS, Android y la web.
Sin cuenta, sin suscripción, sin ningún servidor nuestro entre tú y el modelo.

<a href="../../LICENSE"><img alt="Licencia AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<a href="ios.md"><img alt="iOS 18 y posteriores" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white"></a>
<a href="android.md"><img alt="Android 8 y posteriores" src="https://img.shields.io/badge/Android-8+-A78BFA?style=flat-square&labelColor=black&logo=android&logoColor=white"></a>
<a href="web.md"><img alt="Web construida con Next.js" src="https://img.shields.io/badge/Web-Next.js-A78BFA?style=flat-square&labelColor=black&logo=nextdotjs&logoColor=white"></a>
<img alt="15 proveedores más relay" src="https://img.shields.io/badge/providers-15_+_relay-8B5CF6?style=flat-square&labelColor=black">
<img alt="16 idiomas de interfaz" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

<a href="https://oriveoai.com">Sitio web</a> &nbsp;·&nbsp;
<a href="#empezar">Empezar</a> &nbsp;·&nbsp;
<a href="#arquitectura">Arquitectura</a> &nbsp;·&nbsp;
<a href="#community-edition-y-oriveo">Ediciones</a> &nbsp;·&nbsp;
<a href="#preguntas-frecuentes">Preguntas frecuentes</a> &nbsp;·&nbsp;
<a href="../../CONTRIBUTING.md">Contribuir</a>

<sub>

<a href="../../README.md">English</a> ·
<a href="../ar/README.md">العربية</a> ·
<a href="../de/README.md">Deutsch</a> ·
**Español** ·
<a href="../fr/README.md">Français</a> ·
<a href="../hi/README.md">हिन्दी</a> ·
<a href="../id/README.md">Indonesia</a> ·
<a href="../ja/README.md">日本語</a> ·
<a href="../ko/README.md">한국어</a> ·
<a href="../pt-BR/README.md">Português</a> ·
<a href="../ru/README.md">Русский</a> ·
<a href="../th/README.md">ไทย</a> ·
<a href="../tr/README.md">Türkçe</a> ·
<a href="../vi/README.md">Tiếng Việt</a> ·
<a href="../zh-Hans/README.md">简体中文</a> ·
<a href="../zh-Hant/README.md">繁體中文</a>

</sub>

</div>

---

## Qué es Oriveo

Oriveo Community Edition es un cliente de chat de IA para iOS, Android y la web que funciona con tus
propias claves (BYOK). Tú aportas claves de API que ya tienes, y el cliente habla con el proveedor
usándolas. No hay cuenta de Oriveo, ni suscripción, ni analítica.

Habla de forma nativa con **15 proveedores de modelos** —OpenAI, Anthropic, Google Gemini,
OpenRouter, DeepSeek, Grok, Mistral, Groq, Together AI, Fireworks AI, MiniMax, Z.ai, Qwen, Kimi y
SiliconFlow— y además con **cualquier endpoint compatible con OpenAI, Anthropic o Gemini** al que lo
apuntes, incluidos llama.cpp, Ollama, LM Studio o vLLM corriendo en tu propia máquina.

| | |
|---|---|
| **Proveedores** | 15 integrados, más endpoints Relay propios y servidores de modelos locales |
| **Clientes** | iOS (SwiftUI) · Android (Jetpack Compose) · Web (Next.js) |
| **Idiomas de interfaz** | 16 |
| **Cuenta requerida** | Ninguna |
| **Llamadas que hace por cuenta propia** | Una: un catálogo de modelos de solo lectura, sin clave ni identificador |
| **Licencia** | AGPL-3.0-or-later |

## Por qué existe

Un cliente de chat no debería interponerse entre tú y el modelo que estás pagando.

- **Tus claves, tu factura.** Pagas el precio de lista del proveedor. Nada lleva recargo, ni se mide,
  ni se revende.
- **Local por defecto.** Conversaciones, notas, carpetas, Skills y adjuntos viven en el dispositivo.
  Expórtalos a un archivo cuando quieras; no hay ninguna copia en la nube a la que puedas perder el
  acceso.
- **Un solo comportamiento, tres clientes.** Cómo se arma una solicitud para un proveedor, un
  transporte y una capacidad dados se define una vez en [`shared/`](shared.md), y los tres clientes
  verifican contra los mismos fixtures JSON. Una rareza de un proveedor se arregla una vez, no tres.
- **Honesto sobre la única llamada que hace.** La app descarga un catálogo público de modelos para
  que un modelo lanzado hoy funcione sin actualizar la app. Es de solo lectura, no lleva clave ni
  identificador, y puedes apuntarlo a tu propio host.

## Funciones

- **Chat** — streaming, bloques de razonamiento, citas, adjuntos (imágenes, PDF, Office, EPUB, HTML,
  texto plano), citar una selección, reintentar, regenerar, continuar tras una respuesta interrumpida
- **Proveedores** — 15 integrados, cada uno con tu propia clave; endpoint, modelo y parámetros
  redefinibles por proveedor
- **Relay** — cualquier endpoint compatible con OpenAI, Anthropic o Gemini, incluido uno en tu red
  local
- **Servidores de modelos locales** — llama.cpp, Ollama, LM Studio, vLLM, con descubrimiento en la
  red local
- **Inicio de sesión por suscripción** — usa una suscripción de Codex o Grok que ya tengas en lugar
  de una clave de API
- **Skills** — prompts de sistema reutilizables con su propio modelo, sus parámetros y sus documentos
  de referencia
- **Notas y carpetas** — guarda una respuesta como nota, organiza conversaciones, búsqueda de texto
  completo
- **Cross-check** — vuelve a hacerle la misma pregunta a un segundo modelo y conserva ambas
  respuestas lado a lado
- **Costo** — gasto por mensaje y por proveedor, calculado en el dispositivo a partir de lo que cada
  respuesta reportó realmente, incluidos los niveles de descuento por caché
- **Generación de imágenes** — donde el proveedor la admite
- **Copias de seguridad** — exporta todo a un archivo, cifrado si quieres con una contraseña que tú
  elijas
- **16 idiomas de interfaz**, con diseño completo de derecha a izquierda para el árabe

## Community Edition y Oriveo

Este repositorio es **Oriveo Community Edition**, bajo licencia
[AGPL-3.0-or-later](../../LICENSE). Las apps de la App Store, de Google Play y la app web alojada son
**Oriveo**: un producto propietario aparte, construido a partir de los mismos clientes, con una capa
de cuenta encima.

| | Community Edition | Oriveo |
|---|---|---|
| Código fuente | Este repositorio, AGPL-3.0-or-later | Propietario |
| Chat con tus propias claves de proveedor | Sí | Sí |
| Relay y servidores de modelos locales | Sí | Sí |
| Notas, carpetas, Skills, adjuntos | Sí, sin límite | Sí |
| Seguimiento de costos en el dispositivo | Sí | Sí |
| Cuenta | Ninguna | Cuenta de Oriveo |
| Almacenamiento | En el dispositivo; exportación y restauración manuales | Local primero, más sincronización en la nube entre dispositivos |
| Análisis de uso y alertas de presupuesto | — | Sí |
| Modelos que paga Oriveo | — | Sí |
| Analítica y reportes de fallos | Ninguno | Sí |

Las builds de Community Edition usan el prefijo de identificador `ai.oriveo.community`, así que una
puede convivir con una build de la tienda sin que las dos compartan keychain, canal de
actualizaciones ni datos locales. Lo que esta edición acepta y lo que no está escrito en
[COMMUNITY.md](../../COMMUNITY.md).

**Oriveo, el producto completo:**
[iPhone y iPad](https://apps.apple.com/app/oriveo/id6775370458) &nbsp;·&nbsp;
[Android](https://play.google.com/store/apps/details?id=com.kenny.oriveo) &nbsp;·&nbsp;
[Web](https://app.oriveoai.com) &nbsp;·&nbsp;
[oriveoai.com](https://oriveoai.com)

## Proveedores

A cada proveedor de abajo se llega con una clave que creas tú.

| Proveedor | Dónde conseguir una clave |
|---|---|
| OpenAI | [platform.openai.com](https://platform.openai.com/api-keys) |
| Anthropic | [console.anthropic.com](https://console.anthropic.com/settings/keys) |
| Google Gemini | [aistudio.google.com](https://aistudio.google.com/apikey) |
| OpenRouter | [openrouter.ai](https://openrouter.ai/keys) |
| DeepSeek | [platform.deepseek.com](https://platform.deepseek.com/api_keys) |
| Grok | [console.x.ai](https://console.x.ai/) |
| Mistral | [console.mistral.ai](https://console.mistral.ai/api-keys) |
| Groq | [console.groq.com](https://console.groq.com/keys) |
| Together AI | [api.together.xyz](https://api.together.xyz/settings/api-keys) |
| Fireworks AI | [fireworks.ai](https://fireworks.ai/api-keys) |
| MiniMax | [platform.minimax.io](https://platform.minimax.io/docs/guides/quickstart-preparation) |
| Z.ai | [open.bigmodel.cn](https://open.bigmodel.cn/usercenter/apikeys) |
| Qwen | [bailian.console.alibabacloud.com](https://bailian.console.alibabacloud.com/?apiKey=1#/api-key) |
| Kimi | [platform.kimi.ai](https://platform.kimi.ai/console/api-keys) |
| SiliconFlow | [cloud.siliconflow.cn](https://cloud.siliconflow.cn/account/ak) |
| **Relay** | Cualquier endpoint compatible con OpenAI, Anthropic o Gemini, incluido uno en tu propia máquina |

## Arquitectura

Tres clientes nativos, una sola definición de cómo hablar con un proveedor de modelos.

```mermaid
flowchart LR
    shared["shared/<br/>recetas de solicitud · contratos · fixtures"]

    subgraph clients ["Tres clientes nativos"]
        direction TB
        ios["iOS · SwiftUI"]
        android["Android · Compose"]
        web["Web · Next.js"]
    end

    route["Route handler de Next.js<br/>en la máquina que sirve la app"]

    subgraph upstream ["Se llega con tu clave"]
        official["15 proveedores de modelos"]
        relay["Cualquier relay compatible"]
        local["Un servidor tuyo"]
    end

    catalog[("Catálogo público de modelos<br/>solo lectura · sin clave")]

    shared -.->|"verificado por cada cliente"| clients
    catalog -.->|"capacidades y precios"| clients
    ios & android ==>|"directo desde el dispositivo"| upstream
    web ==> route ==> upstream
```

Cada cliente es dueño de su propia interfaz, su almacenamiento y su navegación, y se encuentra con
los contratos compartidos en exactamente una costura: la capa que convierte *este modelo, esta
capacidad* en una solicitud HTTP.

La única asimetría que vale la pena conocer es el cliente web. Las API de los proveedores no envían
encabezados CORS, así que un navegador no puede llamarlas directamente; por eso las solicitudes a los
15 proveedores oficiales pasan por un route handler de Next.js que corre en la máquina que sirva la
app, la tuya cuando la ejecutas localmente. Los clientes de iOS y Android no tienen esa restricción y
van directo al proveedor. Los endpoints Relay de tu propia red también se llaman directamente desde
el navegador.

**La arquitectura de cada cliente:**

| | Stack | README |
|---|---|---|
| **iOS** | SwiftUI con un hilo en UIKit, GRDB | [ios.md](ios.md) |
| **Android** | Jetpack Compose, Room, Koin, Ktor/OkHttp | [android.md](android.md) |
| **Web** | Next.js App Router, React, Zustand, TypeScript | [web.md](web.md) |
| **Shared** | Contratos, fixtures grabados y el núcleo de protocolo en Swift | [shared.md](shared.md) |

## Empezar

<details open>
<summary><b>Web</b> — la forma más rápida de probarlo</summary>

<br>

Requiere Node 22 (ver [`web/.nvmrc`](../../web/.nvmrc)).

```bash
cd web
npm install
npm run dev:app        # http://localhost:3001
```

La primera pantalla pide una clave de API de un proveedor. No hace falta nada más.
Más comandos y configuración: [web.md](web.md).

</details>

<details>
<summary><b>iOS</b> — compilar y ejecutar en tu propio iPhone</summary>

<br>

Requiere una Mac con Xcode 26 y un dispositivo con iOS 18 o posterior. Basta con una cuenta gratuita
de Apple Developer: la app no usa ninguna capability de pago.

1. Abre `ios/Oriveo/Oriveo.xcodeproj`
2. Selecciona el esquema `Oriveo`
3. En Signing &amp; Capabilities, elige tu propio Team
4. Ejecuta

Guía completa, incluido qué hacer si Xcode se niega a abrir el proyecto: [ios.md](ios.md).

</details>

<details>
<summary><b>Android</b> — compilar el APK</summary>

<br>

Requiere JDK 17 o posterior y el SDK de Android. La build usa AGP 9.3, Gradle 9.5 y Kotlin 2.3, así
que Android Studio tiene que ser una versión capaz de sincronizarlos; desde la línea de comandos solo
hacen falta el JDK y el SDK.

```bash
cd android
./gradlew :app:assembleDebug
```

Servir el catálogo de modelos desde tu propio host: [android.md](android.md).

</details>

## Privacidad

- **Las claves de proveedor** las guarda el mecanismo propio de cada plataforma —el Keychain de iOS,
  el Keystore de Android (`EncryptedSharedPreferences`) o la IndexedDB del navegador— y se usan solo
  para llegar al proveedor al que pertenecen. En la web se guardan sin cifrar, el mismo modelo que
  usan en general los clientes BYOK de navegador; para la garantía más fuerte, usa el cliente de iOS
  o Android.
- **Conversaciones, notas, carpetas, Skills y adjuntos** se guardan en el dispositivo. No se sube
  nada a ninguna parte.
- **Sin cuenta, sin analítica, sin reportes de fallos.** No hay dónde iniciar sesión ni nada que
  llame a casa.
- **En iOS y Android, las solicitudes de chat van directo del dispositivo al proveedor.** En la web
  pasan por el servidor Next.js que sirve la app, porque las API de los proveedores no permiten
  llamadas directas desde el navegador; ese servidor no persiste claves ni mensajes, y cuando
  ejecutas la app localmente es tu propia máquina.
- **Una sola solicitud propia:** un catálogo de modelos de solo lectura, descargado sin clave, sin
  conversación y sin identificador, para que un modelo lanzado hoy funcione sin una build nueva.
  Apúntalo a tu propio host si prefieres servirlo tú.

## Preguntas frecuentes

<details>
<summary><b>¿Qué significa BYOK?</b></summary>

<br>

Bring your own key: trae tu propia clave. Creas una clave de API en la consola del propio proveedor
—OpenAI, Anthropic, Google, etc.— y la pegas en Oriveo. Ese proveedor factura las solicitudes a su
precio de lista. Oriveo es el cliente; no es un revendedor y no se lleva ninguna comisión.

</details>

<details>
<summary><b>¿Mis conversaciones pasan por un servidor de Oriveo?</b></summary>

<br>

No. En iOS y Android el cliente llama al endpoint del proveedor directamente. En la web la solicitud
pasa por el servidor Next.js que está sirviendo la app —tu propia máquina cuando la ejecutas
localmente—, porque los navegadores no pueden llamar a las API de los proveedores directamente.
Ninguno de los dos caminos involucra un servidor operado por Oriveo. La única solicitud que Oriveo
hace por cuenta propia es una descarga de solo lectura del catálogo público de modelos, que no lleva
clave, ni conversación, ni identificador.

</details>

<details>
<summary><b>¿Puedo usar un modelo que corre en mi propia máquina?</b></summary>

<br>

Sí. Agrega una conexión Relay que apunte a cualquier servidor compatible con OpenAI, Anthropic o
Gemini: llama.cpp, Ollama, LM Studio, vLLM o cualquier otra cosa que hable uno de esos protocolos.
Los clientes de Android y web también pueden descubrir un servidor así en la red local. El HTTP local
no usa ninguna credencial y nunca sale de tu red.

</details>

<details>
<summary><b>¿En qué se diferencia de la app de la App Store?</b></summary>

<br>

Las apps de las tiendas son Oriveo, un producto propietario que agrega una cuenta, sincronización en
la nube entre dispositivos, análisis de uso y modelos que paga Oriveo. Community Edition son esos
mismos tres clientes sin nada de eso: sin cuenta, sin servicio de sincronización, sin facturación,
sin analítica. Mira [Community Edition y Oriveo](#community-edition-y-oriveo) para la comparación
completa.

</details>

<details>
<summary><b>¿Hay un cliente para macOS?</b></summary>

<br>

En este repositorio no. Mientras tanto, el cliente web funciona bien como app de escritorio en
cualquier navegador, y la build de iOS corre en Macs con Apple Silicon.

</details>

<details>
<summary><b>¿En qué idiomas está disponible la interfaz?</b></summary>

<br>

En dieciséis: árabe, alemán, inglés, español, francés, hindi, indonesio, japonés, coreano, portugués
de Brasil, ruso, tailandés, turco, vietnamita, chino simplificado y chino tradicional. El árabe tiene
un diseño completo de derecha a izquierda.

</details>

## Estructura del repositorio

```
ios/       iOS client (SwiftUI)
android/   Android client (Jetpack Compose)
web/       Web client (Next.js)
macos/     Reserved for a macOS client
shared/    Cross-client contracts, recorded fixtures, and the Swift wire kernel
```

## Contribuir

Los reportes de errores y los pull requests son bienvenidos.
[CONTRIBUTING.md](../../CONTRIBUTING.md) explica cómo compilar cada cliente y cómo es un buen pull
request; [COMMUNITY.md](../../COMMUNITY.md) describe para qué sirve esta edición y los pocos tipos de
cambio que no se aceptarán por bien escritos que estén.

¿Encontraste un problema de seguridad? Por favor no abras un issue público:
[SECURITY.md](../../SECURITY.md) explica cómo reportarlo en privado, y qué considera este proyecto
una vulnerabilidad y qué no. Se espera que todas las personas que participan sigan el
[código de conducta](../../CODE_OF_CONDUCT.md).

## Licencia

[AGPL-3.0-or-later](../../LICENSE). Las contribuciones se aceptan bajo la misma licencia.
