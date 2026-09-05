import type { QuoteContext } from '@oriveo/shared';

export function selectionAskTelemetryProperties(quoteContext: QuoteContext) {
  return {
    source_role: quoteContext.sourceRole,
    content_kind: quoteContext.contentKind,
  } as const;
}

export function selectionAskElapsedBucket(elapsedMillis: number): string {
  const elapsed = Math.max(0, elapsedMillis);
  if (elapsed < 5_000) return 'under_5s';
  if (elapsed < 30_000) return '5_to_29s';
  if (elapsed < 120_000) return '30_to_119s';
  return '120s_or_more';
}
