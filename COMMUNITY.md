# Scope

Oriveo Community Edition is a local, bring-your-own-key AI client. This page describes
what that means in practice, so that feature proposals and pull requests have a shared
starting point.

[README](README.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) ·
[Code of conduct](CODE_OF_CONDUCT.md)

## The rule

Everything the app does happens on the device, using credentials the user supplies. Chat
completions go to the user's own provider. Notes, folders, skills, conversations, and
attachments are stored locally. The app works fully offline apart from the provider calls
themselves.

There is exactly one network call the app makes on its own behalf: it reads a public model
catalog to learn how each model wants to be addressed — which transport it speaks, which
generation parameters it accepts, how its reasoning controls are named, and what it costs.
That catalog is read-only, unauthenticated, and carries no user data.

## In scope

- Providers reached with a user-supplied key, including self-hosted and OpenAI-compatible
  relays
- Signing in to a provider the user already subscribes to, such as Codex or Grok, using
  that provider's own device-authorization flow
- Local storage: conversations, notes, folders, custom skills, attachments
- Local backup and export
- Cost estimates derived from local message history
- Interface translations
- Anything that improves how the app speaks to a model provider

## Out of scope

- An Oriveo account, or any hosted identity, sync, or backup service
- Billing, subscriptions, entitlements, quotas, or usage tiers
- Inference paid for by anyone other than the user
- Product analytics or crash reporting to a service the user did not configure

A pull request that adds one of these will be closed with a pointer to this page. The
reason is not ideology: the moment the app depends on a service someone else operates, a
user who clones this repository can no longer run the whole thing themselves.

## Identity

Builds from this repository use the `ai.oriveo.community` identifier prefix so they can be
installed alongside a store build without sharing a keychain, an update feed, or local
data.

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
