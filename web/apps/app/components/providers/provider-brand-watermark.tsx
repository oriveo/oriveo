'use client';

import type { ComponentType } from 'react';
import { Sparkles } from 'lucide-react';
import { OFFICIAL_PROVIDER_LOGOS } from '../provider-logo-assets';

/**
 * Single source of truth for the Provider brand watermark, shared by the three hero and showcase
 * cards: ProviderHeroCard, ProviderDetailBrandHero and the ProviderCard on the add page.
 *
 * Two branches:
 * - Official providers use a silhouette cut from the transparent logo.
 * - Relay has no matching official asset, so it keeps a simple motif icon.
 */

const MASK_ASSETS: Record<string, string> = Object.fromEntries(
  Object.entries(OFFICIAL_PROVIDER_LOGOS).map(([kind, pair]) => [kind, pair.light]),
);

/** relay — iOS menuSystemImage / Android AutoAwesome */
function SparkleMark({ size }: { size: number }) {
  return <Sparkles size={size} fill="currentColor" stroke="none" aria-hidden="true" />;
}

const SYMBOL_MARKS: Record<string, ComponentType<{ size: number }>> = {
  relay: SparkleMark,
};

export type ProviderWatermark =
  | { type: 'mask'; asset: string }
  | { type: 'symbol'; Icon: ComponentType<{ size: number }> }
  | null;

/** Given a provider kind, returns how the watermark should be rendered: a mask silhouette, a motif symbol, or nothing. */
export function resolveProviderWatermark(kind: string): ProviderWatermark {
  const Icon = SYMBOL_MARKS[kind];
  if (Icon) return { type: 'symbol', Icon };
  const asset = MASK_ASSETS[kind];
  return asset ? { type: 'mask', asset } : null;
}
