<div align="center">

<img src="../../docs/assets/logo.png" width="104" height="104" alt="Oriveo のロゴ">

# Oriveo Community Edition

**すべてのモデルを、ひとつのアプリで。**

iOS・Android・Web 向けの、オープンソースな BYOK（自分の API キーを使う）AI チャットで、
ネイティブな macOS クライアントも開発中です。
アカウントもサブスクリプションも不要で、チャットのリクエスト経路に私たちのサービスは入りません。

<a href="../../LICENSE"><img alt="ライセンス AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<a href="ios.md"><img alt="iOS 18 以降" src="https://img.shields.io/badge/iOS-18+-A78BFA?style=flat-square&labelColor=black&logo=apple&logoColor=white"></a>
<a href="android.md"><img alt="Android 8 以降" src="https://img.shields.io/badge/Android-8+-A78BFA?style=flat-square&labelColor=black&logo=android&logoColor=white"></a>
<a href="web.md"><img alt="Next.js で作られた Web 版" src="https://img.shields.io/badge/Web-Next.js-A78BFA?style=flat-square&labelColor=black&logo=nextdotjs&logoColor=white"></a>
<a href="macos.md"><img alt="macOS クライアントは開発中" src="https://img.shields.io/badge/macOS-in_development-6D5FA6?style=flat-square&labelColor=black&logo=apple&logoColor=white"></a>
<a href="https://github.com/oriveo/oriveo/releases/latest"><img alt="最新リリース" src="https://img.shields.io/github/v/release/oriveo/oriveo?style=flat-square&labelColor=black&color=8B5CF6"></a>
<a href="https://github.com/oriveo/oriveo/stargazers"><img alt="GitHub のスター数" src="https://img.shields.io/github/stars/oriveo/oriveo?style=flat-square&labelColor=black&color=8B5CF6"></a>

**Oriveo を入手:**
<a href="https://oriveoai.com"><b>oriveoai.com</b></a> &nbsp;·&nbsp;
<a href="https://apps.apple.com/app/oriveo/id6775370458">App Store</a> &nbsp;·&nbsp;
<a href="https://play.google.com/store/apps/details?id=com.kenny.oriveo">Google Play</a> &nbsp;·&nbsp;
<a href="https://app.oriveoai.com">Web アプリ</a>

<sub>ストアで配布しているのは <b>Oriveo</b>、プロプライエタリ版です。このリポジトリは<a href="#community-edition-と-oriveo">Community Edition</a>で、ソースからビルドします。</sub>

<a href="#はじめかた">ソースからビルド</a> &nbsp;·&nbsp;
<a href="#アーキテクチャ">アーキテクチャ</a> &nbsp;·&nbsp;
<a href="#community-edition-と-oriveo">エディション</a> &nbsp;·&nbsp;
<a href="#よくある質問">よくある質問</a> &nbsp;·&nbsp;
<a href="../../CONTRIBUTING.md">コントリビュート</a>

<sub>

<a href="../../README.md">English</a> ·
<a href="../ar/README.md">العربية</a> ·
<a href="../de/README.md">Deutsch</a> ·
<a href="../es/README.md">Español</a> ·
<a href="../fr/README.md">Français</a> ·
<a href="../hi/README.md">हिन्दी</a> ·
<a href="../id/README.md">Indonesia</a> ·
**日本語** ·
<a href="../ko/README.md">한국어</a> ·
<a href="../pt-BR/README.md">Português</a> ·
<a href="../ru/README.md">Русский</a> ·
<a href="../th/README.md">ไทย</a> ·
<a href="../tr/README.md">Türkçe</a> ·
<a href="../vi/README.md">Tiếng Việt</a> ·
<a href="../zh-Hans/README.md">简体中文</a> ·
<a href="../zh-Hant/README.md">繁體中文</a>

</sub>

<img src="../../docs/assets/hero.webp" width="100%" alt="Oriveo Community Edition：あらゆるモデルをひとつのアプリで。15 プロバイダー、700 以上のモデル、iOS・Android・Web。">

</div>

---

## Oriveo とは

Oriveo Community Edition は、iOS・Android・Web 向けのオープンソース（open-source）で
BYOK（bring-your-own-key）なマルチモデル（multi-model）の AI チャットクライアント（AI chat client）
で、ネイティブな macOS クライアントも開発中です。ホスティング型の ChatGPT や Claude のプランに対する
ローカルファーストな代替で、手前に立つ何かにサブスクリプション料を払うより、モデルプロバイダーへ直接
払いたい人のためのものです。すでにお持ちの API キーを登録すると、この LLM クライアント（LLM client）
がそのキーでプロバイダーとやり取りし、Web クライアントは自分でホスト（self-host）できます。Oriveo の
アカウントはなく、こちらへ何かを報告してくるものもありません。

**15 のモデルプロバイダー**（OpenAI、Anthropic、Google Gemini、OpenRouter、DeepSeek、Grok、
Mistral、Groq、Together AI、Fireworks AI、MiniMax、Z.ai、Qwen、Kimi（Moonshot）、SiliconFlow）に
ネイティブ対応しており、さらに **OpenAI・Anthropic・Gemini のいずれかと互換のエンドポイント**であれば
何でも指定できます。手元のマシンで動かしている llama.cpp、Ollama、LM Studio、vLLM も含みます。
ひとつのクライアント、ひと続きの会話、どのモデルが答えても。

<table>
<tr>
<td width="33%" valign="top"><b>15 のプロバイダー</b><br>加えてリレーサービス（Relay）のエンドポイントとローカルのモデルサーバー。</td>
<td width="33%" valign="top"><b>既定でローカル</b><br>会話、ノート、フォルダ、スキル、添付ファイルは端末に残ります。</td>
<td width="33%" valign="top"><b>ひとつの挙動、3 つのクライアント</b><br>仕様は <code>shared/</code> に一度だけ、3 つのテストスイートが検証します。</td>
</tr><tr>
<td valign="top"><b>アカウント不要</b><br>こちらへ報告してくるものはありません。</td>
<td valign="top"><b>自分でホスト</b><br>Web クライアントは自分のマシンで動きます。</td>
<td valign="top"><b>16 言語</b><br>アラビア語には完全な右から左のレイアウト。</td>
</tr></table>

## なぜ作ったのか

あなたがお金を払っているモデルを、誰かが計測したり、記録したり、上乗せしたりできてよいはずが
ありません。

- **あなたのキー、あなたの請求。** 支払うのはプロバイダーの定価です。上乗せも、計測も、再販も
  ありません。
- **既定でローカル。** 会話、ノート、フォルダ、スキル、添付ファイルは端末上に保存されます。いつでも
  ファイルに書き出せますし、アクセスを失うようなクラウド上のコピーは存在しません。
- **ひとつの挙動を、3 つのクライアントで。** あるプロバイダー・トランスポート・機能に対してリクエスト
  をどう組み立てるかは [`shared/`](shared.md) に一度だけ書き下され、3 つのクライアントすべてが同じ
  JSON フィクスチャに対してアサーションします。そのデータの中にある癖なら修正は 1 回で済み、パーサー
  の中にある癖なら 3 つのテストスイートが同時に捕まえます。
- **アプリが取得するたった 1 つのもの。** 公開の読み取り専用モデルカタログ。今日リリースされた
  モデルがアプリの更新なしで使えます。キーも、私たちが付ける識別子も付かず、自分のホストに向ける
  こともできます。

## 機能

- **チャット** — ストリーミング、推論ブロック、引用、添付ファイル（画像と動画、PDF、Office（docx、
  xlsx、pptx）、OpenDocument、EPUB、RTF、HTML、そしてプレーンテキストやソースコードのファイル全般）、
  選択範囲の引用、リトライ、再生成、回答が中断された後の続きの生成
- **プロバイダー** — 15 種類を内蔵し、それぞれ自分のキーを使用。プロバイダーごとにモデルと生成
  パラメーターを上書きでき、プロバイダーが用意している場合はリージョンごとのエンドポイントも選べます
- **リレーサービス** — OpenAI・Anthropic・Gemini 互換のエンドポイントなら何でも。llama.cpp の
  ネイティブ API にも対応し、LAN 内のものも含みます
- **ローカルのモデルサーバー** — llama.cpp、Ollama、LM Studio、vLLM、Open WebUI。iOS と Android は、
  エンジンが自身を告知している場合は mDNS で、そうでなければよく使われるポートを試して見つけます
- **サブスクリプションでのサインイン** — API キーの代わりに、すでに契約している ChatGPT や Grok の
  サブスクリプションを、各プロバイダー自身のデバイス認可フローで利用
- **スキル** — 専用のモデル・推論の設定・参考ドキュメントを持たせられる、再利用可能なシステム
  プロンプト
- **ノートとフォルダ** — 返答をノートとして保存、会話の整理、その両方をまたぐ検索
- **別のモデルで確認** — 回答を 2 つ目のモデルに渡してレビューさせ、両方をまとめて残す
- **メモリー** — 自分についての情報を一度書いておけば、新しい会話のたびに引き継がれます
- **コスト** — メッセージごと・プロバイダーごとの支出を、各レスポンスが実際に報告した内容から端末上で
  計算。キャッシュの読み取りと書き込みの階層も考慮します
- **画像生成** — プロバイダーが対応している場合
- **バックアップ** — すべてをファイルに書き出し。その中のプロバイダーのキーは、含めることを選んだ
  場合、自分で決めたパスワードで暗号化されます
- **16 の UI 言語**。アラビア語には完全な右から左のレイアウトを用意

## Community Edition と Oriveo

このリポジトリは **Oriveo Community Edition** で、[AGPL-3.0-or-later](../../LICENSE) の下で提供
されます。App Store と Google Play のアプリ、およびホスティングされた Web アプリは **Oriveo** です。
こちらはアカウント層を加えた別のプロプライエタリ製品です。

| | Community Edition | Oriveo |
|---|---|---|
| ソース | このリポジトリ、AGPL-3.0-or-later | プロプライエタリ |
| 自分のプロバイダーキーでのチャット | あり | あり |
| リレーサービスとローカルのモデルサーバー | あり | あり |
| ノート、フォルダ、スキル、添付ファイル | あり | あり |
| 端末上でのコスト集計 | あり | あり |
| アカウント | なし | Oriveo アカウント |
| ストレージ | 端末上。書き出しと復元は手動 | ローカルファースト、加えて端末間のクラウド同期 |
| 利用状況の分析と予算アラート | — | あり |
| Oriveo が費用を負担するモデル | — | あり |
| アナリティクスとクラッシュレポート | なし。Web のバンドルの Sentry は、自分の DSN がなければ何も送りません | あり |

Community Edition のビルドは識別子のプレフィックスに `ai.oriveo.community` を使うため、ストア版と
同じ端末に入れても、キーチェーンやローカルデータを一切共有することはありません。このエディション
が受け入れるもの・受け入れないものは [COMMUNITY.md](../../COMMUNITY.md) に書かれています。

**Oriveo 製品:** [iPhone と iPad](https://apps.apple.com/app/oriveo/id6775370458) ·
[Android](https://play.google.com/store/apps/details?id=com.kenny.oriveo) · [Web](https://app.oriveoai.com) · [oriveoai.com](https://oriveoai.com)

## プロバイダー

以下のプロバイダーはすべて、自分で発行したキーで利用します。そのうち 2 つは、キーの代わりに、すでに
契約しているサブスクリプションでサインインして利用することもできます。OpenAI は ChatGPT のプランで、
そして Grok です。

| プロバイダー | キーの取得先 |
|---|---|
| OpenAI | [platform.openai.com](https://platform.openai.com/api-keys) |
| Anthropic | [platform.claude.com](https://platform.claude.com/settings/keys) |
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
| Kimi (Moonshot) | [platform.kimi.ai](https://platform.kimi.ai/console/api-keys) |
| SiliconFlow | [cloud.siliconflow.cn](https://cloud.siliconflow.cn/account/ak) |
| **リレーサービス** | OpenAI・Anthropic・Gemini 互換のエンドポイントなら何でも。llama.cpp のネイティブ API にも対応し、自分のマシン上のものも含みます |

## アーキテクチャ

3 つのネイティブクライアントと、モデルプロバイダーとの話し方に関するひとつの定義。

```mermaid
flowchart LR
    shared["shared/<br/>リクエストレシピ · コントラクト · 録画済みフィクスチャ"]

    subgraph clients ["3 つのネイティブクライアント"]
        direction TB
        ios["iOS · SwiftUI"]
        android["Android · Compose"]
        web["Web · Next.js"]
    end

    route["Next.js route handler<br/>アプリを配信するマシン上"]

    subgraph upstream ["自分の資格情報で到達"]
        official["15 のモデルプロバイダー"]
        relay["互換性のある任意のリレー"]
        local["自分のマシン上のサーバー"]
    end

    catalog[("公開モデルカタログ<br/>読み取り専用 · キーなし")]

    shared -.->|"全クライアントが検証"| clients
    catalog -.->|"機能と価格"| clients
    ios & android ==>|"端末から直接"| upstream
    web ==> route ==> upstream
    web -.->|"CORS 対応のエンドポイントと LAN 内のリレー"| upstream
```

各クライアントは自前の UI・ストレージ・ナビゲーションを持ち、共有コントラクトと接するのはただ 1 か所
だけです。すなわち、*このモデルの、この機能*を HTTP リクエストに変換する層です。

知っておく価値のある非対称性は Web クライアントにひとつだけあります。ほとんどのプロバイダーの API は
CORS ヘッダーを返さないため、ブラウザから直接呼び出せません。そうしたリクエストは、アプリを配信して
いるマシン上で動く Next.js の route handler を経由します。ローカルで動かしているなら、それはあなた
自身のマシンです。ブラウザからの呼び出しを許可している少数のエンドポイント（Kimi の中国向け
エンドポイントと、OpenRouter・SiliconFlow・DeepSeek・Kimi の残高エンドポイント）と、自分の
ネットワーク上のリレーサービスは直接呼び出されます。iOS と Android のクライアントにはこの制約がなく、常にプロバイダーへ直接つなぎます。

**各クライアントのアーキテクチャ:**

| | スタック | README |
|---|---|---|
| **iOS** | SwiftUI と UIKit のメッセージ一覧、GRDB | [ios.md](ios.md) |
| **Android** | Jetpack Compose、Room、Koin、Ktor/OkHttp | [android.md](android.md) |
| **Web** | Next.js App Router、React、Zustand、TypeScript | [web.md](web.md) |
| **macOS** | 開発中。数か月のうちに登場します | [macos.md](macos.md) |
| **Shared** | コントラクト、録画済みフィクスチャ、Swift 製の通信カーネル | [shared.md](shared.md) |

## はじめかた

ここにビルド済みのバイナリはありません。APK も `.ipa` もありません。Community Edition は自分で
ビルドするソースです。動くアプリに最短でたどり着けるのは Web クライアントです。

<details open>
<summary><b>Web</b> — いちばん手早く試せる方法</summary>

<br>

Node 22.22.2 以降の 22.x が必要です（[`web/.nvmrc`](../../web/.nvmrc) を参照）。Node 23 以降には
対応していません。

```bash
cd web
npm install
npm run dev:app        # http://localhost:3001
```

最初の画面でプロバイダーの API キーを尋ねられます。それ以外に必要なものはありません。
コマンドと設定の詳細は [web.md](web.md) にあります。

</details>

<details>
<summary><b>iOS</b> — 自分の iPhone でビルドして実行する</summary>

<br>

Xcode 26 が入った Mac と、iOS 18 以降の実機が必要です。無料の Apple Developer アカウントで十分です
— このアプリは有料の capability を一切使いません。

1. `ios/Oriveo/Oriveo.xcodeproj` を開く
2. `Oriveo` スキームを選ぶ
3. Signing &amp; Capabilities で自分の Team を選ぶ
4. Xcode が `ai.oriveo.community` を登録できない場合は、bundle identifier を自分の Team が保有する
   ものに変更する
5. 実行する

Xcode がプロジェクトを開けない場合の対処も含む詳しい手順は [ios.md](ios.md) にあります。

</details>

<details>
<summary><b>Android</b> — APK をビルドする</summary>

<br>

JDK 21 と Android SDK が必要です。ビルドには AGP 9.3、Gradle 9.5、Kotlin 2.3 を使うため、
Android Studio はこれらを同期できるリリースである必要があります。コマンドラインからなら JDK と SDK
だけで足ります。

```bash
cd android
./gradlew :app:assembleDebug
```

モデルカタログを自分のホストから配信する方法は [android.md](android.md) にあります。

</details>

## プライバシー

- **プロバイダーのキー**は、iOS では Keychain に、Android では Android Keystore が保持する鍵で
  保護された `EncryptedSharedPreferences` に保存されます。ブラウザには相当する仕組みがないため、
  Web では暗号化されないまま IndexedDB に置かれます。これはブラウザベースの BYOK クライアントが
  一般に採る方式です。最も強い保証が欲しい場合は iOS か Android のクライアントをお使いください。
- **会話、ノート、フォルダ、スキル、添付ファイル**は端末上に保存されます。どこにもアップロードされ
  ません。
- **アカウントなし、アナリティクスなし。** サインインする対象はなく、あなたの操作を数えるものも
  ありません。Web のバンドルにはエラー報告用の Sentry が含まれます。`NEXT_PUBLIC_SENTRY_DSN` に
  自分のプロジェクトを設定するまでは何も送りません。設定した場合は、スタックトレースに加えて
  セッションリプレイも記録する構成になっています。iOS と Android のクライアントには報告用の SDK が
  一切入っていません。
- **iOS と Android では、チャットのリクエストは端末からプロバイダーへ直接送られます。** Web では、
  ほとんどのプロバイダーの API がブラウザからの直接呼び出しを許可していないため、その大半はアプリを
  配信している Next.js サーバーを経由します。そのサーバーはキーもメッセージも保存しません。
  ローカルで動かしているならそれはあなた自身のマシンです。
- **私たち自身のリクエストは 2 本:** 読み取り専用のモデルカタログを 2 回の呼び出しで読みます。
  1 つは各モデルをどう呼び出せばよいか、もう 1 つは個々のモデルに関する事実で、iOS が後者を読むのは
  サブスクリプションでサインインした後だけです。おかげで今日リリースされたモデルが新しいビルドなしで
  使えます。どちらもキーも、会話も、私たちが付ける識別子も含みません。ホスト側から見えるのは
  プラットフォーム既定の User-Agent だけで、クライアントが送り返すのはカタログ自身の `ETag` を
  `If-None-Match` として付けたものだけです。Web クライアント（`NEXT_PUBLIC_BACKEND_URL`）と
  Android のビルド（`-PORIVEO_METADATA_BASE_URL`）は自分のホストに向けられます。iOS でのこの
  上書きは Debug ビルド向けの便宜的なものにすぎません。

## よくある質問

<details>
<summary><b>Oriveo は OpenAI・Claude・Gemini・OpenRouter に使える BYOK クライアントですか？</b></summary>

<br>

Bring your own key、つまり「自分のキーを持ち込む」ことです。OpenAI、Anthropic、Google などの
プロバイダーのコンソールで API キーを発行し、それを Oriveo に貼り付けます。リクエストはそのプロバイ
ダーから定価で請求されます。Oriveo はクライアントであって、再販業者ではなく、手数料も取りません。

</details>

<details>
<summary><b>Oriveo は無料でオープンソースな ChatGPT の代替ですか？</b></summary>

<br>

クライアントはそうです。オープンソースで、購読するものはなく、支払いの後ろに隠されている部分も
ありません。支払うのは、自分が投げたリクエストに対するモデルプロバイダー自身の定価で、請求はその
プロバイダーから、キーが属するアカウントに対して行われます。Oriveo がその請求書を見ることは
ありません。

</details>

<details>
<summary><b>会話は Oriveo のサーバーを経由しますか？</b></summary>

<br>

しません。iOS と Android はプロバイダーを直接呼び出します。Web では、ほとんどのプロバイダーの API が
ブラウザからの呼び出しを拒むため、リクエストの大半はアプリを配信している Next.js サーバーを経由
します。ローカルで動かしていれば、それはあなた自身のマシンです。チャットの経路に私たちが運用する
サーバーは入りません。[プライバシー](#プライバシー)を参照してください。

</details>

<details>
<summary><b>Ollama・LM Studio・llama.cpp でも使えますか？</b></summary>

<br>

使えます。OpenAI・Anthropic・Gemini 互換のサーバー（llama.cpp、Ollama、LM Studio、vLLM、
Open WebUI、あるいはそれらのプロトコルを話すものなら何でも）を指すリレーサービス接続を追加して
ください。iOS と Android のクライアントは、エンジンが自身を告知している場合は mDNS で、そうでなければ
よく使われるポートを試して、ローカルネットワーク上から見つけます。Web クライアントは各エンジンで
よく使われるアドレスを提案します。ローカルの HTTP は認証情報を一切使わず、あなたのネットワークから
出ることもありません。

</details>

<details>
<summary><b>Oriveo を自分でホストできますか？</b></summary>

<br>

できます。このプロジェクトでサーバー側を持つのは Web クライアントだけで、キーもメッセージも保存
しません。自分のハードウェアで動くモデルサーバーに向け、`NEXT_PUBLIC_BACKEND_URL`（Web）または
`-PORIVEO_METADATA_BASE_URL`（Android）でカタログも自分でホストすれば、ネットワークの外へ出ていく
ものは何もなくなります。iOS でのこの上書きは Debug ビルドにしかありません。
[プライバシー](#プライバシー)を参照してください。

</details>

<details>
<summary><b>Community Edition は App Store の Oriveo と何が違いますか？</b></summary>

<br>

ストアのアプリは Oriveo で、アカウント、端末間のクラウド同期、利用状況の分析、そして Oriveo が費用を
負担するモデルを備えたプロプライエタリ製品です。Community Edition にそれらはありません。詳しい比較は
[Community Edition と Oriveo](#community-edition-と-oriveo) をご覧ください。

</details>

<details>
<summary><b>macOS 版アプリはありますか？</b></summary>

<br>

ネイティブな macOS クライアントは開発中で、数か月のうちに登場します。置き場所は
[`macos/`](macos.md) です。それまでは、Web クライアントがどのブラウザでもデスクトップアプリとして
十分に使えますし、iOS 版のビルドは Apple シリコンの Mac で Xcode からそのまま動きます。プロバイダーと
通信する Swift パッケージはすでに macOS 15 を宣言しており、Mac クライアントに必要な通信層は今日
すでにテストされています。

</details>

<details>
<summary><b>UI はどの言語に対応していますか？</b></summary>

<br>

16 言語です。アラビア語、ドイツ語、英語、スペイン語、フランス語、ヒンディー語、インドネシア語、
日本語、韓国語、ブラジルポルトガル語、ロシア語、タイ語、トルコ語、ベトナム語、簡体字中国語、
繁体字中国語。アラビア語には完全な右から左のレイアウトが用意されています。

</details>

## リポジトリ構成

```
ios/           iOS クライアント（SwiftUI）
android/       Android クライアント（Jetpack Compose）
web/           Web クライアント（Next.js）
macos/         macOS クライアント — 開発中、数か月のうちに登場
shared/        クライアント共通のコントラクト、録画済みフィクスチャ、Swift 製の通信カーネル
readme_i18n/   これらの README の他 15 言語版
docs/assets/   README で使う画像
llms.txt       このドキュメントの機械可読なインデックス
.github/       Issue と Pull Request のテンプレート
```

## コントリビュート

バグ報告と Pull Request を歓迎します。[CONTRIBUTING.md](../../CONTRIBUTING.md) には各クライアントの
ビルド方法と、良い Pull Request がどういうものかが書かれています。[COMMUNITY.md](../../COMMUNITY.md)
には、このエディションが何のためにあるのか、そしてどれだけよく書かれていても受け入れられない数少ない
種類の変更について書かれています。

セキュリティ上の問題を見つけましたか？公開の issue は立てないでください。非公開で報告する方法と、
このプロジェクトが何を脆弱性として扱い何を扱わないかは [SECURITY.md](../../SECURITY.md) に書かれて
います。参加するすべての人に[行動規範](../../CODE_OF_CONDUCT.md)の遵守をお願いしています。

## ライセンス

[AGPL-3.0-or-later](../../LICENSE)。コントリビュートも同じライセンスの下で受け入れます。

プロバイダー名とロゴはそれぞれの所有者に属し、ここではこのクライアントを向けられるサービスを示す
ためだけに掲載しています。これらはこのリポジトリのライセンスの対象ではなく、掲載は誰かによる推奨を
意味しません。クライアントが同梱しているフォントとライブラリ、およびそれらの条項は
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md) に一覧があります。
