# Shared

Contracts and libraries shared across the iOS, Android, and Web clients, so the same behavior is
defined once instead of copied three times.

## model-contracts

JSON fixtures that pin down cross-client behavior: what a request must look like for a given
provider and capability, how generation parameters resolve and sync between devices, which
capability states each client is allowed to present, and how the model catalog and its evidence
are consumed. Each client's tests load these files directly and assert against them, so a change
here is a change to all three clients at once.

- Path: `shared/model-contracts`

## capabilityrecipe

The recipe registry that tells each client's request builder exactly how to shape a request for a
given provider, transport, and capability (web search, reasoning effort, image generation, and so
on), including the source references the recipes were derived from.

- Path: `shared/capabilityrecipe`

## test-fixtures

Golden test data consumed by all three clients: recorded upstream tool-call traffic, relay
routing and discovery scenarios, model-facts and capability-evidence snapshots, and local-engine
scenarios. Recorded `.sse` files are real captured upstream traffic and are left untouched.

- Path: `shared/test-fixtures`

## OriveoProviderKit

Swift package holding the provider wire-protocol kernel: SSE assembly, OpenAI-compatible chunk
parsing, tool-name codec, credential redaction, upstream error classification, thinking tags,
and per-provider quirk profiles.

- Path: `shared/OriveoProviderKit`
- Platforms: iOS 18+, macOS 15+
- Supported provider kinds are the ones a user can point at with their own API key: the built-in
  OpenAI-compatible catalog plus any relay endpoint they configure themselves.

```bash
cd shared/OriveoProviderKit && swift build && swift test
```
