<div align="center">

# Oriveo for Web

**一个 Next.js 聊天客户端，用来使用你已经在付费的那些 AI 模型。**

<a href="../../LICENSE"><img alt="许可证 AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="Next.js 16" src="https://img.shields.io/badge/Next.js-16-A78BFA?style=flat-square&labelColor=black&logo=nextdotjs&logoColor=white">
<img alt="React 19" src="https://img.shields.io/badge/React-19-A78BFA?style=flat-square&labelColor=black&logo=react&logoColor=white">
<img alt="Node 22" src="https://img.shields.io/badge/Node-22-A78BFA?style=flat-square&labelColor=black&logo=nodedotjs&logoColor=white">
<img alt="16 种界面语言" src="https://img.shields.io/badge/languages-16-8B5CF6?style=flat-square&labelColor=black">

<sub>

<a href="../../web/README.md">English</a> ·
<a href="../ar/web.md">العربية</a> ·
<a href="../de/web.md">Deutsch</a> ·
<a href="../es/web.md">Español</a> ·
<a href="../fr/web.md">Français</a> ·
<a href="../hi/web.md">हिन्दी</a> ·
<a href="../id/web.md">Indonesia</a> ·
<a href="../ja/web.md">日本語</a> ·
<a href="../ko/web.md">한국어</a> ·
<a href="../pt-BR/web.md">Português</a> ·
<a href="../ru/web.md">Русский</a> ·
<a href="../th/web.md">ไทย</a> ·
<a href="../tr/web.md">Türkçe</a> ·
<a href="../vi/web.md">Tiếng Việt</a> ·
**简体中文** ·
<a href="../zh-Hant/web.md">繁體中文</a>

</sub>

</div>

---

Oriveo Web 客户端是一个用 Next.js 构建的、自带 Key 的 AI 聊天 App。对话、笔记、文件夹、Skills 以及
你的供应商 Key 都存在浏览器自己的存储里。没有账号，也不需要登录。

它是 [Oriveo 社区版](README.md) 的一部分 —— 三个客户端共用同一份「怎么和模型供应商说话」的定义。

## 快速开始

需要 Node 22（见 [`.nvmrc`](../../web/.nvmrc)）。npm 随它一起发布；不需要别的包管理器。

```bash
npm install
npm run dev:app     # http://localhost:3001
```

第一屏会问你要一个供应商的 API Key。开始聊天不需要别的东西。

## 一个请求实际是怎么走的

这一节值得先于其它任何内容读，因为 Web 客户端是唯一一处请求**不是**从客户端直达供应商的地方。

```mermaid
flowchart LR
    browser["浏览器<br/>React · Zustand · IndexedDB"]

    subgraph server ["Next.js route handler · Node runtime"]
        direction TB
        chat["/api/chat/stream"]
        fwd["/api/relay/forward"]
    end

    official["15 家官方供应商"]
    pubrelay["公网主机上的 relay"]
    lan["你网络里的模型服务器"]
    catalog[("公开模型目录<br/>只读 · 不带 Key")]

    browser ==>|"官方供应商"| chat ==> official
    browser ==>|"relay，公网主机"| fwd ==> pubrelay
    browser ==>|"relay，局域网或 localhost"| lan
    catalog -.-> browser
    catalog -.-> chat
```

**为什么要绕这一下。** 供应商的 API 不发 CORS 头，浏览器没法直接调用 `api.openai.com` 之流 ——
预检请求就会失败。每一个浏览器 BYOK 客户端都得想办法解决这件事；这一个的做法是转发给一个跑在 Node
runtime 里的 Next.js route handler。当你跑 `npm run dev:app` 时，那个 handler 就在你自己机器上。
当你把应用部署到某处时，它就在你部署到的那台机器上。

**这个 handler 做什么、不做什么。** 它校验请求形状并限制大小，施加按 IP 的限流，拒绝解析到私有地址或
链路本地地址的 URL，构造供应商特有的请求体，然后把响应流式传回。它不保存你的 Key、你的消息，也不保存
任何由它们派生出来的东西 —— 有一个专门的测试（`server-never-learns.test.ts`）钉死了这个行为。relay
转发器还额外把 DNS 钉在它解析出的那个地址上，限制响应大小，给每个超时设上界，把重定向限制在同源
范围内，并拒绝透传逐跳（hop-by-hop）头部。

**本地端点完全跳过它。** 位于私有地址、`.local` 名称、`localhost` 上的 relay，或者配置成本地 HTTP
或私有 VPN 模式的 relay，都是**由浏览器直接**请求的，带 `credentials: 'omit'` 和
`targetAddressSpace: 'local'`。你的局域网流量不会离开你的网络，也不会经过这个应用的服务器。

## 架构

```mermaid
flowchart TB
    subgraph app ["apps/app —— Next.js 应用"]
        direction LR
        routes["App Router<br/>聊天 · 笔记 · 供应商 · Skills · 设置"]
        store["Zustand store<br/>vanilla + context"]
        idb[("IndexedDB<br/>对话 · 笔记 · Key")]
    end

    subgraph pkgs ["packages/ —— 与运行时无关"]
        direction LR
        core["core<br/>传输 · 请求构造 · SSE"]
        shared["shared<br/>领域类型 · relay 策略"]
        ui["ui<br/>设计 token · 组件"]
        config["config<br/>品牌 · 供应商默认值"]
    end

    ports["CorePorts<br/>传输 · 加密 · 时钟 · 埋点 · 元数据 · 环境"]

    routes <--> store <--> idb
    store --> core
    core --> shared & config
    routes --> ui
    core <--> ports
```

`packages/core` 持有关于供应商协议的每一个字节的知识，并被刻意保持得不碰任何浏览器全局对象 ——
eslint 在它内部禁用了 `window`、`document`、`fetch`、`crypto`、`localStorage` 和 `indexedDB`。它需要
从环境里拿的一切都经由 `CorePorts` 到达。正是这一点，让同一份代码可以跑在浏览器里、跑在 Node route
handler 里，也可以跑在一个没有 DOM 的测试里。

供应商支持是两条互相独立的轴。`providerKind` 挑选一个**请求构造器**（这家厂商的请求体长什么样）。
`model.transport` 从十二种里挑选一个**传输策略**（实际说的是哪种线上协议），而且它是按模型、从目录
解析出来的，不是按供应商 —— 所以同一个 Key 后面的两个模型完全可以不一致。一个策略只实现三个方法：
`buildRequestBody`、`parseStreamChunk`、`parseError`。

## 工作区

```
apps/app/               the Next.js application
packages/core/          provider protocols: transports, request builders, SSE parsing
packages/shared/        domain types, relay policy, helpers
packages/ui/            design tokens and shared components
packages/config/        brand and provider defaults
packages/ipc-contract/  typed channel contract for a desktop shell
```

样式是 CSS Modules 叠在 `packages/ui` 里一张统一的自定义属性 token 表上 —— 没有用任何原子类框架。
`packages/ipc-contract` 描述的是一个桌面壳会绑定的通道界面；本仓库里并没有这样的壳，所以在 Web 构建
上它只贡献一些永远走不到的类型和分支。

## 存储

一切都按分区隔离，由一个默认为 `guest` 的活跃 id 作为键。

| 内容 | 位置 |
|---|---|
| 对话、消息、文件夹、笔记、供应商 | IndexedDB `oriveo--{id}`，8 个 object store |
| 模型目录快照（约 3 MB）和 model facts | IndexedDB blob store，刻意不放 localStorage |
| 偏好设置和模型控制项表 | `localStorage`，一律经由一个永不抛异常的包装层 |
| 生成的和附加的图片 | 一个单独的 IndexedDB 数据库 |

有两个细节来自真实的翻车，而不是审美偏好。目录快照放在 IndexedDB 里，是因为它约 3 MB，会吃掉一个
浏览器 origin 那 5 MB localStorage 配额的大半。而每一次 localStorage 访问都要走 `safeLocalStorage`，
是因为当浏览器被配置为阻止站点数据时，`window.localStorage` 这个 *getter* 本身就会抛
`SecurityError` —— 一次裸读会在你的 `try` 块开始执行之前就把页面搞崩。

> [!IMPORTANT]
> 在 Web 上，供应商 Key 是**明文**存在 IndexedDB 里的 —— 这也是基于浏览器的 BYOK 客户端普遍采用的
> 方式，因为浏览器没有更好的地方可放。想要最强的保证，请用 iOS 或 Android 客户端，那里由系统的
> keychain 或 keystore 加密它们。备份归档是另一回事：当你设定密码时，它们用 AES-256-GCM 和
> PBKDF2-SHA-256 迭代 600,000 次加密。

## 模型目录

每家供应商提供哪些模型、每个模型支持什么，来自启动时拉取的一份只读目录。只请求两个端点，都是 `GET`，
都带 ETag 条件，都不携带 API Key、对话或任何用户标识：

```
GET {backend}/api/metadata?view=lean
GET {backend}/api/metadata/model-facts
```

默认后端是 `https://api.oriveoai.com`。把 `NEXT_PUBLIC_BACKEND_URL` 指向你自己的服务器就能自己提供
它。响应在 IndexedDB 里缓存 24 小时，并用 `If-None-Match` 重新校验；目录不可达时，应用仍能靠缓存
副本继续工作。

## 命令

在当前目录下运行这些命令。

| 命令 | 作用 |
|---|---|
| `npm run dev:app` | 在 3001 端口启动开发服务器 |
| `npm run build:app` | 生产构建 |
| `npm run typecheck` | 对每个 workspace 执行 `tsc --noEmit` |
| `npm run test:run` | vitest，跑一遍 |
| `npm run test` | vitest 监听模式 |
| `npm run lint` | 对 `apps/` 和 `packages/` 执行 eslint |

要跑单个测试文件，请在拥有它的那个 workspace 里跑，因为有几套测试是相对工作目录解析 fixture 的：

```bash
cd apps/app && npx vitest run lib/core/chat/stream-options.test.ts
```

## 配置

所有配置都是可选的。把 [`.env.example`](../../web/.env.example) 复制成 `.env.local`，只设置你需要的
那些；每个键在那里都有说明。

## 测试

461 个文件里大约 4,600 个测试，跑在 vitest 上。覆盖最密的地方也是出错代价最高的地方：每家供应商的
请求形状、每种线上协议的传输行为、SSE 与代理分片解析、用量与花费解析、错误分类、relay 探测与安全
模式、SSRF 防护、能力配方执行、目录缓存与契约版本失效、IndexedDB 持久化、存储分区、备份往返一致性，
以及 route handler 本身。

> [!IMPORTANT]
> 大约 24 个套件从 `../shared` 加载契约 fixture，所以**测试只有在完整 checkout 里才能通过** ——
> 把 `web/` 单独拷出来是跑不起来的。

## 本地化

`apps/app/messages` 里有十六个 locale，每个约 1,800 个键，英语是源语言。有一个测试会遍历这个目录，
一旦某个 locale 的键集与英语不同就失败，所以新增一个 locale 文件就会自动把它纳入。阿拉伯语有完整的
从右到左布局。locale 的选取顺序是：显式的 `?locale=` 参数，然后 cookie，然后 `Accept-Language`。

## 参与贡献

见 [CONTRIBUTING.md](../../CONTRIBUTING.md)。`packages/core` 是传输优先的：新增一家供应商通常只是
一个请求构造器加一个响应适配器，而不是一个新客户端。修供应商协议问题时，优先用 `shared/test-fixtures`
下录制的 fixture 而不是手写的 mock。

## 许可证

[AGPL-3.0-or-later](../../LICENSE)。
