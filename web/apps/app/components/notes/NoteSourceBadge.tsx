'use client';

import type { ProviderKind } from '@oriveo/shared';
import type { CSSProperties } from 'react';
import { ProviderIcon } from '../ProviderIcon';
import { relayIconSource } from '../relay-avatar';
import { PROVIDER_BRAND_COLORS } from '../../lib/constants/provider-brand-colors';
import styles from './Notes.module.css';

interface NoteSourceBadgeProps {
  providerKind?: ProviderKind;
  providerName?: string;
  modelName?: string;
  compact?: boolean;
}

export function NoteSourceBadge({ providerKind, providerName, modelName, compact = false }: NoteSourceBadgeProps) {
  if (!providerKind) return null;
  const color = PROVIDER_BRAND_COLORS[providerKind]?.light ?? PROVIDER_BRAND_COLORS.relay.light;
  const label = modelName || providerName || providerKind;

  return (
    <span
      className={styles.sourceBadge}
      data-compact={compact ? 'true' : undefined}
      style={{ '--note-source-color': color } as CSSProperties}
      title={label}
    >
      <span className={styles.sourceBadgeIcon}>
        {/* Notes do not record the connection: relay sources are always generic and are not inferred from the name */}
        <ProviderIcon kind={providerKind} size={compact ? 13 : 14} bare {...relayIconSource(null)} />
      </span>
      {!compact ? <span className={styles.sourceBadgeText}>{label}</span> : null}
    </span>
  );
}
