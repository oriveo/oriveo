# Oriveo for macOS

A native macOS client is in development and will be released in the coming months. It is not in
this repository yet — this directory is where it will land, next to the other three clients.

It is being built as a Mac application rather than a resized phone app: real windows, the keyboard
shortcuts you already have muscle memory for, and the same local-first storage the other clients
use. Like them it is bring-your-own-key, and it meets the same shared provider contracts, so a
protocol quirk fixed once is fixed everywhere.

## What already runs on a Mac

- **The web client**, which makes a perfectly good desktop app in any browser:

  ```bash
  cd web
  npm install
  npm run dev:app        # http://localhost:3001
  ```

  See [web/README.md](../web/README.md).

- **The iOS build**, on an Apple silicon Mac. Open `ios/Oriveo/Oriveo.xcodeproj`, choose the
  *My Mac (Designed for iPad)* destination, and run. See [ios/README.md](../ios/README.md).

## What is already written

The wire layer a Mac client needs exists and is under test today.
[`shared/OriveoProviderKit`](../shared/OriveoProviderKit/) — the Swift package that turns *this
model, this capability* into an HTTP request, and the same package the iOS app links against —
declares macOS 15 alongside iOS 18 in its
[`Package.swift`](../shared/OriveoProviderKit/Package.swift):

```swift
platforms: [.macOS(.v15), .iOS(.v18)]
```

Its suite runs on macOS with no simulator involved:

```bash
cd shared/OriveoProviderKit
swift build && swift test
```

[Root README](../README.md) · [Shared contracts](../shared/README.md)
