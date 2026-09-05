'use client';

import React from 'react';
import { useTranslations } from 'next-intl';
import * as Sentry from '@sentry/nextjs';
import type { ModelCapability } from '@oriveo/shared';
import styles from './ModelCapabilityBadge.module.css';

type BadgeSize = 'xs' | 'sm' | 'md';

const ICON_SIZE_BY_SIZE: Record<BadgeSize, number> = {
  xs: 10,
  sm: 11,
  md: 12,
};

/**
 * Presentation contract:
 *   - the static table below maps a capability literal to its icon and label i18n key
 *   - a lookup miss falls back to a grey dot plus the capitalized literal, so the card still renders
 *   - an unknown capability is reported to Sentry as `metadata.unknown_capability`
 *   - this component only renders icon and copy; the model row must first project the evidence
 *     facade result into visible literals through `visibleModelCapabilityBadges`
 */

type KnownCapability = Exclude<ModelCapability, 'text'> | 'toolCall';

const KNOWN_CAPABILITIES: KnownCapability[] = [
  'reasoning',
  'image',
  'video',
  'file',
  'web',
  'imageGeneration',
  'toolCall',
];

const LABEL_KEY: Record<KnownCapability, string> = {
  reasoning: 'reasoning',
  image: 'image',
  video: 'video',
  file: 'file',
  web: 'web',
  imageGeneration: 'imageGeneration',
  toolCall: 'toolCall',
};

function isKnownCapability(value: string): value is KnownCapability {
  return (KNOWN_CAPABILITIES as string[]).includes(value);
}

function renderCapabilityIcon(capability: KnownCapability, size: BadgeSize): React.ReactNode {
  const iconSize = ICON_SIZE_BY_SIZE[size];

  switch (capability) {
    case 'reasoning':
      return (
        <svg width={iconSize} height={iconSize} viewBox="0 0 16 16" fill="none">
          <path
            d="M8 1.5C5.1 1.5 2.75 3.85 2.75 6.75c0 1.8.9 3.38 2.25 4.33V12.5c0 .55.45 1 1 1h4c.55 0 1-.45 1-1v-1.42A5.24 5.24 0 0 0 13.25 6.75C13.25 3.85 10.9 1.5 8 1.5ZM6.5 14.25h3M8 4v2.5M6 6.5h4"
            stroke="currentColor"
            strokeWidth="1.3"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      );
    case 'image':
      return (
        <svg width={iconSize} height={iconSize} viewBox="0 0 16 16" fill="none">
          <rect x="2" y="2" width="12" height="12" rx="2" stroke="currentColor" strokeWidth="1.3" />
          <circle cx="5.5" cy="5.5" r="1.25" stroke="currentColor" strokeWidth="1.3" />
          <path d="M2 11l3-3 2 2 3-3 4 4" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      );
    case 'video':
      return (
        <svg width={iconSize} height={iconSize} viewBox="0 0 16 16" fill="none">
          <rect x="2" y="3.5" width="9" height="9" rx="1.6" stroke="currentColor" strokeWidth="1.3" />
          <path d="M11 6.2l3-1.7v7l-3-1.7V6.2Z" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round" />
        </svg>
      );
    case 'file':
      return (
        <svg width={iconSize} height={iconSize} viewBox="0 0 16 16" fill="none">
          <path
            d="M13.5 5.5l-4.3-4.3a1 1 0 0 0-.7-.3H4.5a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h7a2 2 0 0 0 2-2V6.2a1 1 0 0 0-.3-.7Z"
            stroke="currentColor"
            strokeWidth="1.3"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <path d="M8.5 1v4a1 1 0 0 0 1 1h4" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
        </svg>
      );
    case 'web':
      return (
        <svg width={iconSize} height={iconSize} viewBox="0 0 16 16" fill="none">
          <circle cx="8" cy="8" r="6" stroke="currentColor" strokeWidth="1.3" />
          <path d="M2 8h12M8 2c1.66 1.46 2.6 3.63 2.6 6s-.94 4.54-2.6 6c-1.66-1.46-2.6-3.63-2.6-6S6.34 3.46 8 2Z" stroke="currentColor" strokeWidth="1.3" />
        </svg>
      );
    case 'imageGeneration':
      return (
        <svg width={iconSize} height={iconSize} viewBox="0 0 16 16" fill="none">
          <path
            d="M11.5 1.5l-1.2 1.2M2.5 10.5l-1 4 4-1 8.3-8.3a1.4 1.4 0 0 0-2-2L3.5 11.5Z"
            stroke="currentColor"
            strokeWidth="1.3"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          <path d="M9.5 3.5l3 3" stroke="currentColor" strokeWidth="1.3" />
        </svg>
      );
    case 'toolCall':
      return (
        <svg width={iconSize} height={iconSize} viewBox="0 0 16 16" fill="none">
          <path d="M6 3.25H3.75A1.75 1.75 0 0 0 2 5v6.25A1.75 1.75 0 0 0 3.75 13h6.5A1.75 1.75 0 0 0 12 11.25V9" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          <path d="M8.25 7.75 13.5 2.5M10 2.5h3.5V6" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      );
  }
}

export const CAPABILITY_ICONS: Record<KnownCapability, React.ReactNode> = {
  reasoning: renderCapabilityIcon('reasoning', 'sm'),
  image: renderCapabilityIcon('image', 'sm'),
  video: renderCapabilityIcon('video', 'sm'),
  file: renderCapabilityIcon('file', 'sm'),
  web: renderCapabilityIcon('web', 'sm'),
  imageGeneration: renderCapabilityIcon('imageGeneration', 'sm'),
  toolCall: renderCapabilityIcon('toolCall', 'sm'),
};

const unknownReported = new Set<string>();

function reportUnknownCapability(value: string, providerId?: string): void {
  // Do not report the same capability twice.
  const dedupeKey = `${value}|${providerId ?? ''}`;
  if (unknownReported.has(dedupeKey)) return;
  unknownReported.add(dedupeKey);
  console.warn('[metadata] unknown capability', { capability: value, providerId });
  // A capability literal the client does not know means the metadata contract drifted, which is
  // worth an issue rather than a silent breadcrumb. Uses the existing @sentry/nextjs plus tags
  // style, same as the sync-initial captureMessage.
  Sentry.captureMessage('metadata: unknown model capability', {
    level: 'warning',
    tags: { module: 'metadata.unknown_capability' },
    extra: { capability: value, providerId: providerId ?? null },
  });
}

/**
 * Test-only: clear the unknown capability dedup set.
 *
 * The module-level `unknownReported` set is a per-process singleton, so state shared across test
 * cases makes dedup hit by accident. It is not named `resetUnknownReported` so production code
 * does not reach for it by mistake (the `__` prefix convention, matching metadata-client's
 * `__resetVersionListenersForTest`).
 */
export function __resetUnknownReportedForTest(): void {
  unknownReported.clear();
}

function formatUnknownLabel(value: string): string {
  if (!value) return '?';
  return value.charAt(0).toUpperCase() + value.slice(1);
}

interface ModelCapabilityBadgeProps {
  /** Display-only capability literal; model capability is not decided here. */
  capability: string;
  size?: BadgeSize;
  /** Optional provider id, used as a tag when reporting an unknown capability. */
  providerId?: string;
  /** Compact mode: render the icon only, with the text moved to title/aria-label as a hover tooltip. */
  iconOnly?: boolean;
}

export function ModelCapabilityBadge({ capability, size = 'md', providerId, iconOnly = false }: ModelCapabilityBadgeProps) {
  const t = useTranslations('capability');

  if (capability === 'text') return null;

  if (isKnownCapability(capability)) {
    const label = t(LABEL_KEY[capability]);
    return (
      <span
        className={styles.badge}
        data-size={size}
        data-cap={capability}
        data-icon-only={iconOnly || undefined}
        data-tooltip={iconOnly ? label : undefined}
        aria-label={iconOnly ? label : undefined}
      >
        <span className={styles.icon}>{renderCapabilityIcon(capability, size)}</span>
        {iconOnly ? null : label}
      </span>
    );
  }

  // Unknown capability fallback: grey dot plus the capitalized literal, so the card still renders.
  reportUnknownCapability(capability, providerId);
  const fallback = formatUnknownLabel(capability);
  return (
    <span
      className={styles.badge}
      data-size={size}
      data-cap="unknown"
      data-icon-only={iconOnly || undefined}
      data-tooltip={iconOnly ? fallback : undefined}
      aria-label={`Unknown capability: ${capability}`}
    >
      <span className={styles.icon} aria-hidden="true">
        <span className={styles.unknownDot} />
      </span>
      {iconOnly ? null : fallback}
    </span>
  );
}

interface ModelCapabilityBadgesProps {
  /** Model rows pass the facade projection; static filter chips may pass literal constants. */
  capabilities: string[];
  size?: BadgeSize;
  /** Optional provider id, used as a tag when reporting an unknown capability. */
  providerId?: string;
  /** Optional badgeOrder from the backend `uiHints.badgeOrder` - a capability missing from it is not shown. */
  badgeOrder?: string[];
  /** Compact mode: render the icon only. */
  iconOnly?: boolean;
}

export function ModelCapabilityBadges({
  capabilities,
  size = 'md',
  providerId,
  badgeOrder,
  iconOnly = false,
}: ModelCapabilityBadgesProps) {
  const visible = capabilities.filter((c) => c !== 'text');
  if (visible.length === 0) return null;

  // Presentation contract:
  //   - when badgeOrder is given, only the metadata capabilities it lists are shown, in that order
  //   - toolCall is a UI-only capability the client projects from tool_call evidence; the server's
  //     badgeOrder never contains it, so it is appended whenever evidence exists instead of being
  //     dropped by an order list that does not know about it
  //   - a capability absent from badgeOrder is not shown at all
  //   - a capability listed in badgeOrder that the client does not recognize gets the grey dot
  //     fallback rather than being skipped
  //   - without badgeOrder, fall back to the original `capabilities` order for older metadata
  const ordered = badgeOrder && badgeOrder.length > 0
    ? orderByBadgeOrder(visible, badgeOrder)
    : visible;
  if (ordered.length === 0) return null;

  return (
    <span className={styles.badges} data-size={size} data-icon-only={iconOnly || undefined}>
      {ordered.map((cap) => (
        <ModelCapabilityBadge
          key={cap}
          capability={cap}
          size={size}
          providerId={providerId}
          iconOnly={iconOnly}
        />
      ))}
    </span>
  );
}

function orderByBadgeOrder(capabilities: string[], badgeOrder: string[]): string[] {
  const indexByCap = new Map<string, number>();
  badgeOrder.forEach((cap, index) => indexByCap.set(cap, index));

  // Dedupe and filter: keep only what badgeOrder lists, in badgeOrder's order.
  const seen = new Set<string>();
  const filtered: string[] = [];
  for (const cap of capabilities) {
    if (seen.has(cap)) continue;
    if (!indexByCap.has(cap)) continue;
    seen.add(cap);
    filtered.push(cap);
  }
  filtered.sort((left, right) => (indexByCap.get(left)! - indexByCap.get(right)!));
  if (capabilities.includes('toolCall') && !seen.has('toolCall')) filtered.push('toolCall');
  return filtered;
}
