# Shared MCP fixtures (single source for all clients)

iOS, Android and web all run the **same** files: protocol replays, authorization replays, naming,
hashing, address classification, argument summaries, the safety prompt text and a local mock server.
This directory is the executable form of the pure functions that every client must implement
identically, character for character.

> **Adding a file here changes the contract.** Agree on the behaviour first, then have every client
> consume the new vectors at the same time; adding an assertion to a single client without touching
> this directory forks the contract.

## Layout

```text
shared/test-fixtures/mcp/
├── README.md                      this file (the inventory; update it whenever the directory changes)
├── naming.json                    tool-name rule vectors (normal / illegal characters / too long / collisions)
├── identifiers.json               slug generation ([a-z0-9] only) and tool-name sanitisation boundary vectors (by UTF-16 code unit)
├── tool-hash.json                 content-hash vectors (equivalent with different key order / one character of the description changed / parameter definition changed)
├── local-only.json                vectors for deciding whether an address carries a secret (three criteria)
├── args-summary.json              argument-summary vectors
├── safety-prompt.txt              fixed prompt text appended when MCP tools are enabled (English, identical on every client)
├── mock-server.mjs                local mock server (single Node file, zero dependencies, loopback only)
├── protocol/
│   ├── stateless/                 2026-07-28 (stateless, no handshake)
│   │   ├── discover.request.json          server/discover request (with per-request _meta and the full header set)
│   │   ├── discover.response.json         the server's self-reported supportedVersions / capabilities
│   │   ├── tools-list.request.json        modern request used to probe the protocol generation
│   │   ├── tools-list.response.json       tools array (including untrusted hints such as annotations)
│   │   ├── tools-call.request.json        call request, Mcp-Method / Mcp-Name required
│   │   ├── tools-call.response.json       successful response in JSON form
│   │   ├── tools-call.sse.txt             successful response in SSE form (with a notification in between)
│   │   ├── error.unsupported-protocol-version.json   -32022 + data.supported
│   │   ├── error.header-mismatch.json                 -32020
│   │   └── error.missing-required-capability.json     -32021
│   ├── session/                   2025-11-25 (initialize handshake + session)
│   │   ├── initialize.request.json        first step of the handshake
│   │   ├── initialize.response.json       response header carries MCP-Session-Id
│   │   ├── initialized.notification.json  the notification a client MUST send
│   │   ├── tools-list.request.json        carries MCP-Protocol-Version + MCP-Session-Id
│   │   ├── tools-list.response.json       legacy shape without resultType
│   │   ├── tools-call.request.json        legacy call (no Mcp-Method / Mcp-Name needed)
│   │   ├── tools-call.response.json       legacy successful response
│   │   ├── tools-call.sse.txt             SSE form
│   │   ├── error.unknown-tool.json        -32602
│   │   └── error.session-terminated.json  404 → must initialize again without the session header
│   └── shared/                    common to both generations / generation-independent
│       ├── tools-call.structured-content.response.json   falls back to structuredContent when content is empty
│       ├── tools-call.is-error.response.json             isError: true (not a JSON-RPC error)
│       ├── tools-call.input-required.response.json       resultType = input_required (MRTR)
│       ├── tools-call.input-required.retry.request.json  new id + inputResponses + requestState
│       ├── error.invalid-params.json                     -32602 (required _meta field missing, with modern markers)
│       ├── error.legacy-before-initialize.json           400 + generic -32602 (no modern markers) → must fall back to initialize
│       ├── error.method-not-found.json                   404 + -32601 (with a JSON-RPC body) → classified as modern
│       └── not-mcp.responses.json                        four kinds of "not an MCP response"
└── auth/
    ├── 401.www-authenticate.json   401 + resource_metadata + scope
    ├── 401.no-metadata.json        401 without resource_metadata → construct the well-known URI
    ├── protected-resource-metadata.json                  RFC 9728
    ├── authorization-server-metadata.cimd.json           supports CIMD
    ├── authorization-server-metadata.dcr.json            supports DCR only
    ├── authorization-server-metadata.none.json           supports neither
    ├── authorization-server-metadata.issuer-mismatch.json  issuer check fails and must be rejected
    ├── authorization-request.json   authorization request parameters + per-request record (PKCE / state / issuer)
    ├── callback.params.json         RFC 9207 2×2 decision table for callback parameters (including a state mismatch)
    ├── token.request.json           token request (resource is mandatory)
    ├── token.success.json           success
    ├── token.refresh.success.json   successful refresh
    ├── token.error.json             three failures
    ├── dcr.json                     dynamic registration request and response (application_type: native)
    └── 403.insufficient-scope.json  insufficient scope at run time (step-up is not implemented)
```

## Conventions

- **Request fixtures** (`*.request.json`) have the shape `{ method, path, headers, body }`. `headers`
  holds every header that protocol generation requires, so a fixture can be replayed directly in
  `URLProtocol`, OkHttp MockWebServer or Node.
- **Response fixtures** have the shape `{ status, headers, body }`; raw byte forms (SSE, HTML) use the
  `raw` field.
- The `expect` field is the expected value for assertions, not part of the protocol; changing it
  changes the rule being tested.
- `collidesWith` in `naming.json` lists the **original names of the other tools in the same request**
  (not outbound names that are already taken). Collision detection compares the sanitised base of
  each name: `"create.issue"` and `"create_issue"` both sanitise to `create_issue`, so they collide.
  Comparing `collidesWith` as if it held outbound names would miss collisions.
- Every token, session id and client_id in the fixtures is a **fake value**, not a credential.

## Local mock server

`mock-server.mjs` is a single Node file with zero dependencies that listens on the loopback address
only; the integration tests of every client run against it. Command-line arguments select the mode:
`stateless` / `session` / `token` / `oauth-cimd` / `oauth-dcr` / `error` / `slow` (default delay
3000 ms), plus `--sse` (SSE response form) and `--mutable-tools` (the tool list changes from one
call to the next).
