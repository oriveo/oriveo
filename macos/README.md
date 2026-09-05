# macOS

There is no macOS client in this repository yet. This directory is a placeholder so the layout
matches the other clients.

Two things work well in the meantime:

- **The web client** runs as a desktop app in any browser — `cd web && npm run dev:app`. See
  [web/README.md](../web/README.md).
- **The iOS build** runs on Apple silicon Macs straight from Xcode. See
  [ios/README.md](../ios/README.md).

The Swift package under [`shared/OriveoProviderKit`](../shared/README.md) already declares macOS 15
as a supported platform, so the provider wire layer a macOS client would need is here and tested.
