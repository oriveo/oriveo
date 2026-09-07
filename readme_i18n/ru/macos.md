<div align="center">

# Oriveo для macOS

**Нативный клиент для Mac, в разработке.**

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
<a href="../pt-BR/macos.md">Português</a> ·
**Русский** ·
<a href="../th/macos.md">ไทย</a> ·
<a href="../tr/macos.md">Türkçe</a> ·
<a href="../vi/macos.md">Tiếng Việt</a> ·
<a href="../zh-Hans/macos.md">简体中文</a> ·
<a href="../zh-Hant/macos.md">繁體中文</a>

</sub>

</div>

---

Нативный клиент для macOS в разработке и выйдет в ближайшие месяцы. В этом репозитории его пока нет —
именно этот каталог станет его местом, рядом с тремя другими клиентами.

Его делают как приложение для Mac, а не как растянутое приложение с телефона: настоящие окна,
клавиатурные сокращения, которые у вас уже в мышечной памяти, и то же local-first хранение, что и у
остальных клиентов. Как и они, он работает со своим ключом и соблюдает те же общие контракты
провайдеров, так что причуда протокола, исправленная один раз, исправлена везде.

## Что уже работает на Mac

- **Веб-клиент** — из него получается вполне приличное настольное приложение в любом браузере. См.
  [web.md — Быстрый старт](web.md#быстрый-старт).

- **Сборка для iOS** — на Mac с Apple silicon. Откройте `ios/Oriveo/Oriveo.xcodeproj`, выберите
  destination *My Mac (Designed for iPad)* и запустите. См. [ios.md](ios.md).

## Что уже написано

Сетевой слой, нужный клиенту для Mac, существует и уже под тестами.
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — Swift-пакет, который превращает *эту
модель и эту возможность* в HTTP-запрос, и тот же пакет, с которым линкуется приложение iOS, —
объявляет macOS 15 рядом с iOS 18 в своём
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift):

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

Его набор тестов идёт на macOS без всякого симулятора:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

## Лицензия

[AGPL-3.0-or-later](../../LICENSE).

[Корневой README](README.md) · [Общие контракты](shared.md)
