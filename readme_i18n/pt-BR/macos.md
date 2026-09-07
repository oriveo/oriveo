<div align="center">

# Oriveo para macOS

**Um cliente nativo para Mac, em desenvolvimento.**

<sub>

<a href="../../macos/README.md">English</a> ·
<a href="../ar/macos.md">العربية</a> ·
<a href="../de/macos.md">Deutsch</a> ·
<a href="../es/macos.md">Español</a> ·
<a href="../fr/macos.md">Français</a> ·
<a href="../hi/macos.md">हिन्दी</a> ·
<a href="../id/macos.md">Indonesia</a> ·
<a href="../ja/macos.md">日本語</a> ·
<a href="../ko/macos.md">한국어</a> ·
**Português** ·
<a href="../ru/macos.md">Русский</a> ·
<a href="../th/macos.md">ไทย</a> ·
<a href="../tr/macos.md">Türkçe</a> ·
<a href="../vi/macos.md">Tiếng Việt</a> ·
<a href="../zh-Hans/macos.md">简体中文</a> ·
<a href="../zh-Hant/macos.md">繁體中文</a>

</sub>

</div>

---

Um cliente nativo para macOS está em desenvolvimento e será lançado nos próximos meses. Ele ainda
não está neste repositório — este diretório é onde ele vai ficar, ao lado dos outros três clientes.

Ele está sendo feito como um aplicativo de Mac, e não como um app de celular redimensionado: janelas
de verdade, os atalhos de teclado que as suas mãos já decoraram, e o mesmo armazenamento local-first
que os outros clientes usam. Como eles, é bring-your-own-key, e cumpre os mesmos contratos
compartilhados de provedor, então uma peculiaridade de protocolo corrigida uma vez fica corrigida em
todo lugar.

## O que já roda em um Mac

- **O cliente web**, que dá um app de desktop perfeitamente bom em qualquer navegador. Veja
  [web.md — Início rápido](web.md#início-rápido).

- **O build de iOS**, em um Mac com Apple silicon. Abra `ios/Oriveo/Oriveo.xcodeproj`, escolha o
  destino *My Mac (Designed for iPad)* e rode. Veja [ios.md](ios.md).

## O que já está escrito

A camada de protocolo de que um cliente Mac precisa existe e está sob teste hoje.
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — o pacote Swift que transforma *este
modelo, esta capacidade* em uma requisição HTTP, e o mesmo pacote com que o app iOS se liga —
declara o macOS 15 ao lado do iOS 18 no seu
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift):

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

A suíte dele roda no macOS sem nenhum simulador envolvido:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

## Licença

[AGPL-3.0-or-later](../../LICENSE).

[README raiz](README.md) · [Contratos compartilhados](shared.md)
