'use client';

import { useTranslations } from 'next-intl';
import type { ProviderKind, RelayKind } from '@oriveo/shared';
import { ProviderIcon } from '../ProviderIcon';
import { ChevronDownIcon } from '../icons';
import styles from './TopBar.module.css';

interface ModelTriggerProps {
  modelName?: string;
  providerKind?: ProviderKind;
  /**
   * Protocol type selected for a relay provider, which decides whose logo the icon shows:
   * openai_compatible / codex_style -> OpenAI; anthropic_compatible -> Anthropic;
   * gemini_compatible -> Gemini; custom or unset -> the Relay logo.
   */
  relayKind?: RelayKind;
  onModelClick?: () => void;
}

/**
 * Top bar model trigger: provider icon, model name with the free suffix stripped, a Free badge and a chevron.
 */
export function ModelTrigger({ modelName, providerKind, relayKind, onModelClick }: ModelTriggerProps) {
  const t = useTranslations('pages.modelSwitcher');
  // Free model names usually carry a "(free)" suffix; the UI already shows a Free chip, so the
  // suffix is dropped to avoid repeating it.
  const cleanModelName = modelName?.replace(/\s*\(free\)\s*$/i, '').trim() || modelName;
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
          <ProviderIcon kind="relay" relayKind={relayKind} size={18} bare />
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
