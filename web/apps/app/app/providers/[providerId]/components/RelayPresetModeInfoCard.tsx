'use client';

import type { CSSProperties } from 'react';
import { useTranslations } from 'next-intl';
import { ChevronRight, ShieldCheck } from 'lucide-react';
import type { RelayKind } from '@oriveo/shared';
import { RELAY_KIND_OPTIONS } from '../../../../components/providers/RelayKindPicker';
import styles from './RelayPresetModeInfoCard.module.css';

interface RelayPresetModeInfoCardProps {
  relayKind: RelayKind;
  onSwitchToCustom: () => void;
}

export function RelayPresetModeInfoCard({ relayKind, onSwitchToCustom }: RelayPresetModeInfoCardProps) {
  const tr = useTranslations('pages.relayDetail');
  const option = RELAY_KIND_OPTIONS.find((opt) => opt.kind === relayKind);
  const accent = option?.accent ?? '#64748b';

  return (
    <button
      type="button"
      className={styles.card}
      style={{ ['--kind-accent' as never]: accent } as CSSProperties}
      onClick={onSwitchToCustom}
    >
      <span className={styles.iconBox} aria-hidden="true">
        <ShieldCheck size={14} strokeWidth={2.4} />
      </span>
      <div className={styles.stack}>
        <span className={styles.title}>{tr('presetModeTitle')}</span>
        <span className={styles.desc}>{tr('presetModeDesc')}</span>
      </div>
      <ChevronRight size={14} strokeWidth={2.6} className={styles.chevron} aria-hidden="true" />
    </button>
  );
}
