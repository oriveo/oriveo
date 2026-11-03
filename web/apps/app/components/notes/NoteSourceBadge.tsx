'use client';

import type { ProviderKind } from '@oriveo/shared';
import type { CSSProperties } from 'react';
import { ProviderIcon } from '../ProviderIcon';
import { relayIconSource } from '../relay-avatar';
import { providerTextTint, providerTint } from '../usage/provider-tints';
import styles from './Notes.module.css';

/**
 * Per-note source colour variables: `--note-source-color` keeps the raw brand colour for fills,
 * `--note-source-text` / `--note-source-text-dark` carry the text variant per appearance.
 * Without a provider only the primary fallback is set; the CSS defaults derive the text vars from it.
 */
export function noteSourceVars(providerKind?: ProviderKind): CSSProperties {
  if (!providerKind) return { '--note-source-color': 'var(--o-primary)' } as CSSProperties;
  // Same brand table as iOS / Android providerTint. Notes carry no connection id, so Relay passes no
  // seed (hashes on "relay", like iOS fallbackId ""); an empty-string seed would pick a different colour.
  return {
    '--note-source-color': providerTint(providerKind),
    '--note-source-text': providerTextTint(providerKind, undefined, false),
    '--note-source-text-dark': providerTextTint(providerKind, undefined, true),
  } as CSSProperties;
}

interface NoteSourceBadgeProps {
  providerKind?: ProviderKind;
  providerName?: string;
  modelName?: string;
  compact?: boolean;
}

export function NoteSourceBadge({ providerKind, providerName, modelName, compact = false }: NoteSourceBadgeProps) {
  if (!providerKind) return null;
  const label = modelName || providerName || providerKind;

  return (
    <span
      className={styles.sourceBadge}
      data-compact={compact ? 'true' : undefined}
      style={noteSourceVars(providerKind)}
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
