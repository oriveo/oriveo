/**
 * Relay groups that allow only the official CLI client (fixture `negative-cache.v1.json` clientGateRules).
 * It is neither a key problem (key-access records none) nor a route-level rejection (switching protocol in the same group still gets 403), so the protocol is not switched and a single guidance sentence is shown.
 */
const RELAY_CLIENT_GATE_STATUSES: ReadonlySet<number> = new Set([403]);
export const RELAY_CLIENT_GATE_PHRASES: readonly string[] = [
  'official claude cli',
  'restricted to claude code clients',
  '标准 claude code 客户端',
];

/** PHP json_encode escapes `/` as `\/` by default; each phrase is registered in one form only and is unescaped before comparison. */
export function unescapeRelayJSONSlashes(body: string): string {
  return body.replace(/\\\//g, '/');
}

export function isRelayClientGateRejection(status: number | null | undefined, body: string | null | undefined): boolean {
  if (typeof status !== 'number' || !RELAY_CLIENT_GATE_STATUSES.has(status)) return false;
  const normalized = unescapeRelayJSONSlashes(body ?? '').toLowerCase();
  return RELAY_CLIENT_GATE_PHRASES.some((phrase) => normalized.includes(phrase));
}
