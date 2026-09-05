export function mergeExecutionResponse(
  response: Response,
  executionHeaders: Record<string, string>,
  continuation?: { kind: string; protocol: string; responseParserKind: string },
): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(executionHeaders)) headers.set(key, value);
  if (continuation) {
    headers.set('X-Oriveo-Continuation-Kind', continuation.kind);
    headers.set('X-Oriveo-Continuation-Protocol', continuation.protocol);
    headers.set('X-Oriveo-Continuation-Parser', continuation.responseParserKind);
  }
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}
