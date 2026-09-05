# Oriveo Web

The Oriveo web client: a Next.js chat app that talks to the model providers you supply keys for.
Keys, conversations, notes, and skills live in the browser.

## Requirements

Node 22 (see [`.nvmrc`](.nvmrc)). npm ships with it; no other package manager is needed.

## Run it

```bash
npm install
npm run dev:app     # http://localhost:3001
```

The first screen asks for a provider API key. Nothing else is required to start chatting.

## Commands

Run these from this directory.

| Command | What it does |
|---|---|
| `npm run dev:app` | development server on port 3001 |
| `npm run build:app` | production build |
| `npm run typecheck` | `tsc --noEmit` across every workspace |
| `npm run test:run` | vitest, one pass |
| `npm run test` | vitest in watch mode |
| `npm run lint` | eslint over `apps/` and `packages/` |

To run a single test file, do it from the workspace that owns it, because several suites resolve
fixtures relative to the working directory:

```bash
cd apps/app && npx vitest run lib/core/chat/stream-options.test.ts
```

## Layout

```
apps/app/            Next.js application
packages/core/       provider protocols: transports, request builders, SSE parsing
packages/shared/     types and helpers shared by the app and core
packages/ui/         design tokens and shared components
packages/config/     brand and provider defaults
packages/ipc-contract/  typed channel contract for the desktop bridge
```

Contract fixtures shared with the other clients live in `../shared`. Several tests read them
directly, so those suites need the whole repository checked out, not just `web/`.

## Configuration

Everything is optional. Copy [`.env.example`](.env.example) to `.env.local` and set only what you
need; each key is documented there.

## Model catalog

Which models each provider offers, and what each of them supports, comes from a read-only catalog
the app fetches at startup from `https://api.oriveoai.com`, so a newly released model appears
without a new build. Only `/api/metadata`, `/api/metadata/model-facts` and
`/api/metadata/self-heal-events` are requested, and no API key, conversation or user identifier is
sent with them. Point `NEXT_PUBLIC_BACKEND_URL` at your own host to serve the catalog yourself; the
app keeps working from its cached copy when the catalog is unreachable.

## Notes

- Provider keys are stored in the browser and sent only to that provider's endpoint.
- `packages/core` is transport-first: adding a provider usually means a request builder and a
  response adapter, not a new client.
- Interface strings live in `apps/app/messages`. English is the source locale; a test keeps every
  other locale on the same key set.
