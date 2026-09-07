<div align="center">

# Oriveo para macOS

**Un cliente de Mac nativo, en desarrollo.**

<sub>

<a href="../../macos/README.md">English</a> ·
<a href="../ar/macos.md">العربية</a> ·
<a href="../de/macos.md">Deutsch</a> ·
**Español** ·
<a href="../fr/macos.md">Français</a> ·
<a href="../hi/macos.md">हिन्दी</a> ·
<a href="../id/macos.md">Indonesia</a> ·
<a href="../ja/macos.md">日本語</a> ·
<a href="../ko/macos.md">한국어</a> ·
<a href="../pt-BR/macos.md">Português</a> ·
<a href="../ru/macos.md">Русский</a> ·
<a href="../th/macos.md">ไทย</a> ·
<a href="../tr/macos.md">Türkçe</a> ·
<a href="../vi/macos.md">Tiếng Việt</a> ·
<a href="../zh-Hans/macos.md">简体中文</a> ·
<a href="../zh-Hant/macos.md">繁體中文</a>

</sub>

</div>

---

Hay un cliente nativo de macOS en desarrollo y se publicará en los próximos meses. Todavía no está en
este repositorio: este directorio es donde va a aterrizar, junto a los otros tres clientes.

Se está construyendo como una aplicación de Mac y no como una app de teléfono estirada: ventanas de
verdad, los atajos de teclado que ya tienes en la memoria muscular, y el mismo almacenamiento local
primero que usan los demás clientes. Como ellos, funciona con tus propias claves, y cumple los mismos
contratos compartidos de proveedor, así que una rareza de protocolo arreglada una vez queda arreglada
en todas partes.

## Qué corre ya en un Mac

- **El cliente web**, que funciona perfectamente bien como app de escritorio en cualquier navegador.
  Mira [web.md — Inicio rápido](web.md#inicio-rápido).

- **La build de iOS**, en un Mac con Apple Silicon. Abre `ios/Oriveo/Oriveo.xcodeproj`, elige el
  destino *My Mac (Designed for iPad)* y ejecuta. Mira [ios.md](ios.md).

## Qué está ya escrito

La capa de protocolo que necesita un cliente de Mac existe y está bajo prueba hoy.
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) —el paquete de Swift que convierte
*este modelo, esta capacidad* en una solicitud HTTP, y el mismo paquete al que enlaza la app de
iOS— declara macOS 15 junto a iOS 18 en su
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift):

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

Su suite corre en macOS sin ningún simulador de por medio:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

## Licencia

[AGPL-3.0-or-later](../../LICENSE).

[README raíz](README.md) · [Contratos compartidos](shared.md)
