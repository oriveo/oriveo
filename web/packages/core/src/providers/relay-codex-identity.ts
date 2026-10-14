/**
 * Codex identity semantics for Relay (zero-dependency pure computation): injection criterion, client version, and User-Agent.
 * Shared by direct connection (relay-adapter) and the server reverse proxy (apps/app `/api/relay/forward`); do not keep separate copies.
 */

/** Built-in fallback version: used when the Server did not deliver one, the delivered value is invalid, or the runtime config is not loaded yet. */
export const CODEX_CLIENT_VERSION_FALLBACK = '0.162.1';

// Only three-part pure-numeric versions are accepted. The version is spliced into request headers, so pre-release suffixes, newlines, etc. are all rejected.
const CODEX_CLIENT_VERSION_PATTERN = /^\d{1,6}\.\d{1,6}\.\d{1,6}$/;

/** Get the Codex client version: use the input (delivered value / value from the proxy config) if valid, otherwise fall back to the built-in value. */
export function resolveCodexClientVersion(value: unknown): string {
  return typeof value === 'string' && CODEX_CLIENT_VERSION_PATTERN.test(value)
    ? value
    : CODEX_CLIENT_VERSION_FALLBACK;
}

/** User-Agent of the Codex identity; the version is validated here, so callers passing an unvalidated value is also safe. */
export function codexIdentityUserAgent(version: unknown): string {
  return `codex_cli_rs/${resolveCodexClientVersion(version)} (Oriveo Web; Node.js)`;
}

/** Whether the Codex identity headers are injected. The identity headers and the request body's `prompt_cache_key` share this one criterion; do not keep separate copies. */
export function relayInjectsCodexIdentity(
  config: { transport?: string; authMode?: string; codexCompatIdentity?: boolean },
): boolean {
  return config.authMode !== 'none'
    && config.transport === 'openai_responses'
    && config.codexCompatIdentity !== false;
}
