<div align="center">

# Oriveo pour macOS

**Un client Mac natif, en développement.**

<sub>

<a href="../../macos/README.md">English</a> ·
<a href="../ar/macos.md">العربية</a> ·
<a href="../de/macos.md">Deutsch</a> ·
<a href="../es/macos.md">Español</a> ·
**Français** ·
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

Un client macOS natif est en développement et sortira dans les prochains mois. Il n'est pas encore
dans ce dépôt — ce répertoire est l'endroit où il atterrira, à côté des trois autres clients.

Il est construit comme une application Mac et non comme une app de téléphone agrandie : de vraies
fenêtres, les raccourcis clavier dont vous avez déjà la mémoire musculaire, et le même stockage
local-first que les autres clients utilisent. Comme eux, il fonctionne avec vos propres clés, et il
respecte les mêmes contrats fournisseur partagés : une bizarrerie de protocole corrigée une fois est
corrigée partout.

## Ce qui tourne déjà sur un Mac

- **Le client web**, qui fait parfaitement office d'app de bureau dans n'importe quel navigateur :

  ```bash
  cd web
  npm install
  npm run dev:app        # http://localhost:3001
  ```

  Voir [web.md](web.md).

- **Le build iOS**, sur un Mac Apple Silicon. Ouvrez `ios/Oriveo/Oriveo.xcodeproj`, choisissez la
  destination *My Mac (Designed for iPad)*, et lancez. Voir [ios.md](ios.md).

## Ce qui est déjà écrit

La couche protocole dont un client Mac a besoin existe et est testée dès aujourd'hui.
[`shared/OriveoProviderKit`](../../shared/OriveoProviderKit/) — le package Swift qui transforme *ce
modèle, cette capacité* en une requête HTTP, et le même package auquel l'app iOS se lie — déclare
macOS 15 aux côtés d'iOS 18 dans son
[`Package.swift`](../../shared/OriveoProviderKit/Package.swift) :

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

Sa suite tourne sur macOS sans aucun simulateur :

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

[README racine](README.md) · [Contrats partagés](shared.md)
