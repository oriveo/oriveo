'use client';

import { useTranslations } from 'next-intl';
import type { Provider, ProviderKind, RelayKind } from '@oriveo/shared';
import { ProviderIcon } from '../ProviderIcon';
import { relayIconSource } from '../relay-avatar';
import { ChevronDownIcon } from '../icons';
import { stripFreeSuffix } from '../../lib/utils/strip-free-suffix';
import styles from './TopBar.module.css';

interface ModelTriggerProps {
  modelName?: string;
  providerKind?: ProviderKind;
  /** Only local-engine connections still show a logo by protocol type; relay connections use the unified avatar. */
  relayKind?: RelayKind;
  /** The relay connection of the current conversation: its avatar is resolved from the display name and address. */
  relayProvider?: Provider;
  onModelClick?: () => void;
}

/**
 * Top bar model trigger: provider icon, model name with the free suffix stripped, a Free badge and a chevron.
 */
export function ModelTrigger({ modelName, providerKind, relayKind, relayProvider, onModelClick }: ModelTriggerProps) {
  const t = useTranslations('pages.modelSwitcher');
  // Free model names usually carry a "(free)" suffix; the UI already shows a Free chip, so the
  // suffix is dropped to avoid repeating it.
  const cleanModelName = modelName === undefined ? undefined : stripFreeSuffix(modelName);
  const isFreeProvider = false;

  return (
    <button
      type="button"
      className={styles.modelTrigger}
      onClick={onModelClick}
      aria-label={t('switchModel')}
      title={t('switchModel')}
    >
      {providerKind && providerKind !== 'relay' && (
        <span
          className={styles.modelTriggerBadge}
          aria-hidden="true"
        >
          <ProviderIcon kind={providerKind} size={18} bare />
        </span>
      )}
      {providerKind === 'relay' && (
        <span className={styles.modelTriggerBadge} aria-hidden="true">
          <ProviderIcon kind="relay" relayKind={relayKind} size={18} bare {...relayIconSource(relayProvider)} />
        </span>
      )}
      <span className={styles.modelName}>{cleanModelName ?? t('selectModel')}</span>
      {isFreeProvider && (
        <span className={styles.freeTag} aria-label={t('freeModelBadge')}>
          FREE
        </span>
      )}
      <ChevronDownIcon className={styles.chevron} />
    </button>
  );
}
