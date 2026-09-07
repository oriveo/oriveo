<div align="center">

# 共享契约

**一份关于「怎么和模型供应商说话」的定义，由三个客户端共同断言。**

<a href="../../LICENSE"><img alt="许可证 AGPL-3.0-or-later" src="https://img.shields.io/badge/license-AGPL--3.0--or--later-8B5CF6?style=flat-square&labelColor=black"></a>
<img alt="Swift 6.1 包" src="https://img.shields.io/badge/Swift-6.1-A78BFA?style=flat-square&labelColor=black&logo=swift&logoColor=white">
<img alt="JSON 契约" src="https://img.shields.io/badge/contracts-JSON-A78BFA?style=flat-square&labelColor=black">

<sub>

<a href="../../shared/README.md">English</a> ·
<a href="../ar/shared.md">العربية</a> ·
<a href="../de/shared.md">Deutsch</a> ·
<a href="../es/shared.md">Español</a> ·
<a href="../fr/shared.md">Français</a> ·
<a href="../hi/shared.md">हिन्दी</a> ·
<a href="../id/shared.md">Indonesia</a> ·
<a href="../ja/shared.md">日本語</a> ·
<a href="../ko/shared.md">한국어</a> ·
<a href="../pt-BR/shared.md">Português</a> ·
<a href="../ru/shared.md">Русский</a> ·
<a href="../th/shared.md">ไทย</a> ·
<a href="../tr/shared.md">Türkçe</a> ·
<a href="../vi/shared.md">Tiếng Việt</a> ·
**简体中文** ·
<a href="../zh-Hant/shared.md">繁體中文</a>

</sub>

</div>

---

三个客户端如果各自独立实现「调用供应商」这件事，它们一定会漂移。它们会悄悄地漂，朝着最近有人测过的
那一个的方向漂，而漂移最终会以一个「在某个平台上能复现、在另外两个上不能」的 bug 浮出水面。

`shared/` 就是对这件事的回答：行为以数据的形式写下一次，每个客户端的测试套件都对着同一批文件做断言。
住在这份数据里的怪癖修一次就够。住在解析器里的那种，会被三套测试同时抓住，而不是在两个平台上顺利
发布、把第三个搞坏。

```mermaid
flowchart LR
    subgraph contracts ["shared/"]
        direction TB
        recipes["capabilityrecipe<br/>请求该怎么构造"]
        models["model-contracts<br/>客户端可以做什么"]
        fixtures["test-fixtures<br/>录制的上游流量"]
        kit["OriveoProviderKit<br/>Swift 协议内核"]
    end

    iosT["iOS 测试套件"]
    andT["Android 测试套件"]
    webT["Web 测试套件"]

    recipes & models & fixtures --> iosT & andT & webT
    kit --> iosT
```

## capabilityrecipe

配方注册表。对于给定的供应商、传输方式和能力 —— 联网搜索、思考强度、图像生成 —— 它精确说明该往外发的
请求里写入哪些 JSON pointer，以及该怎么把答案读回来。

正是它让今天新发布的模型不用更新客户端就能用，也正是它让任何客户端都不会从模型名字去猜能力。
`capability_runtime.v1.json` 承载配方本身；`capability_result_definitions.v1.json` 和
`capability_custom_controls.v2.json` 定义结果与面向用户的控制项该如何解读。

每条配方都声明一个 `executionKind` —— `request_overlay`、`server_tool`、`client_tool_loop`、
`endpoint_route`、`model_route`、`external_connector`、`unavailable` —— 每个客户端的编译器都会在应用
之前校验这条配方与供应商、能力和传输方式是否匹配，不匹配就以一个具名理由拒绝，而不是发出一个没人
审过的请求。这个列表是一个闭集：配方里写了别的名字，会被拒绝，而不是被猜着处理。

## model-contracts

用来钉死跨客户端行为的 JSON fixture：对于给定的供应商和能力，一个请求必须长什么样；生成参数如何解析、
覆盖项如何叠加；客户端可以呈现哪些能力状态；以及模型目录及其证据该如何被消费。

每个客户端的测试都直接加载这些文件，所以这里的一处改动就是对三个客户端同时的改动。

## test-fixtures

黄金测试数据：录制的上游工具调用流量、中转站（Relay）路由、表单校验、本地地址分类、目录与可移植配置场景、
model-facts 和能力证据快照，以及本地引擎场景。

`provider-toolcall/recorded/` 下面的 `.sse` 文件是**真实捕获的上游流量**，按它到达时的样子逐字节
保留 —— 只丢掉了响应头，而响应体里从来没有带过 Key。直接放在 `provider-toolcall/` 下的 `.sse`
文件则是手写的 fixture，用来钉住某一条具体的解析路径。这个区分是要紧的：手写的 mock 编码的是你以为供应商会做什么，而一份录制下来的流编码的是它当时实际做了什么，包括那个
星期二它发来的那个畸形分片。当一个供应商协议修复需要测试时，优先用录制。

一份 fixture 的 `$comment`，或者它旁边的 `expected.json` 清单，会说明它周围那些条目钉住的是什么。
加新用例之前先读这个。

## OriveoProviderKit

一个 Swift 包，装着供应商线上协议的内核：SSE 行组装、OpenAI 兼容的分片解析、针对 Responses /
Anthropic Messages / Gemini 三种协议的事件式组装、与传输无关的请求构造、配方编译及其执行守卫、
工具名编码、凭证脱敏、上游错误分类、thinking 标签解析、流式 JSON 路径提取、一份显式的 `URLSession`
重定向策略，以及各供应商的怪癖档案。

它的边界是刻意划窄的。**在内：**只依赖 Foundation 的协议知识。**在外：**App 模型、UI、数据库、埋点、
本地化。这个包除了标准库和 Foundation 之外不依赖任何东西，而每个 Apple 客户端在它外面保留一层薄绑定，
好让线上行为只有一份实现。

它为 Apple 平台实现了完整的请求与流式链路。iOS App 目前只链接其中的一个子集 —— 流组装器、线上档案、
工具名编解码器和错误分类器 —— 并保留自己的请求构造器；正在开发的 macOS 客户端是它的第二个消费者，
这也正是配方编译器和与传输无关的请求构造器住在这里、而不是住在某一个 App 里的原因。下面那套测试覆盖
的是每个消费者共用的部分：SSE 切分、OpenAI 兼容组装、工具名编解码器和重定向策略。

```bash
cd shared/OriveoProviderKit && swift build && swift test
```

- 平台：iOS 18+、macOS 15+ · `swift-tools-version: 6.1`
- `ProviderWireProfile` 承载的是单个 OpenAI 兼容组装器仍然需要的那些残余的、各家不同的怪癖 ——
  思考文本从哪里来、缓存 token 计数放在哪里、prompt token 是否已经包含缓存命中。它描述的是*字节以何种
  方式到达*，从不描述*一个模型能做什么*；那是配方的活。

## 改动这些文件

这里的一处改动就是对每个客户端的改动。请把读了你所改文件的每个客户端的契约测试都跑一遍，而不是只跑
你恰好正在做的那个：

从仓库根目录运行：

```bash
(cd web && npm run test:run)
(cd shared/OriveoProviderKit && swift test)
# plus the iOS and Android suites — see their READMEs
```

iOS 那套测试是从测试文件一路向上走、直到看见 `shared/` 来定位这个目录的；Android 那套同样是一路
向上走，只不过从工作目录开始；Web 那套则是相对 workspace 解析它。因此它们全都要求仓库的完整
checkout。

开 Pull Request 之前，请先读 [CONTRIBUTING.md](../../CONTRIBUTING.md)。

## 许可证

[AGPL-3.0-or-later](../../LICENSE)。
