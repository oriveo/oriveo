export function extractCrosscheckDisplayBody(body: string): string {
  const lines = body.split('\n');
  const index = lines.findIndex((line) => line.trim().startsWith('## Cross-check'));
  if (index < 0) return body;
  return lines.slice(index + 1).join('\n').trim() || body;
}

export function noteDisplayBody(body: string, bodySnapshot?: string): string {
  if (!bodySnapshot?.trim()) return body;
  if (!body.includes('\n## Cross-check')) return body;
  return extractCrosscheckDisplayBody(body);
}
