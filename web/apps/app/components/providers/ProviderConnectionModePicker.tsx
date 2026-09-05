'use client';

/**
 * The API key versus subscription sign-in choice on providers that offer both.
 *
 * The caller only inserts this when the server serves a subscription config that the kill switch
 * has not turned off, so availability is not decided here and this component only renders. With
 * no served config the picker never appears and the add flow looks exactly as it does without
 * the feature.
 *
 * The copy namespace and the testId prefix come from the caller: Grok and Codex each need their
 * own description ("use your SuperGrok quota" versus "use your ChatGPT Plus/Pro quota"), but the
 * layout is identical, so there is no reason to maintain two copies of the same button group.
 */

import { CircleCheck, Circle, KeyRound, UserRoundCheck } from 'lucide-react';
import { useTranslations } from 'next-intl';
import type { ProviderAuthMode } from '@oriveo/shared';
import styles from './ProviderSubscription.module.css';

interface ProviderConnectionModePickerProps {
  mode: ProviderAuthMode;
  onChange: (mode: ProviderAuthMode) => void;
  /** next-intl namespace, for example `pages.providerSetup.grokSubscription`. */
  namespace: string;
  /** testId prefix, so `grok` yields `grok-mode-api-key`. */
  testIdPrefix: string;
}

export function ProviderConnectionModePicker({
  mode,
  onChange,
  namespace,
  testIdPrefix,
}: ProviderConnectionModePickerProps) {
  const t = useTranslations(namespace);

  const option = (
    target: ProviderAuthMode,
    icon: React.ReactNode,
    title: string,
    description: string,
    testId: string,
  ) => {
    const selected = mode === target;
    return (
      <button
        type="button"
        role="radio"
        aria-checked={selected}
        data-testid={testId}
        className={[styles.modeOption, selected ? styles.modeOptionSelected : '']
          .filter(Boolean)
          .join(' ')}
        onClick={() => onChange(target)}
      >
        <span className={styles.modeIcon} aria-hidden="true">
          {icon}
        </span>
        <span className={styles.modeCopy}>
          <span className={styles.modeOptionTitle}>{title}</span>
          <span className={styles.modeOptionDesc}>{description}</span>
        </span>
        <span className={styles.modeRadio} aria-hidden="true">
          {selected ? <CircleCheck size={18} strokeWidth={2.2} /> : <Circle size={18} strokeWidth={2} />}
        </span>
      </button>
    );
  };

  return (
    <div className={styles.modeSection}>
      <div className={styles.modeTitle}>{t('modeTitle')}</div>
      <div className={styles.modeOptions} role="radiogroup" aria-label={t('modeTitle')}>
        {option(
          'apiKey',
          <KeyRound size={16} strokeWidth={2.2} />,
          t('apiKeyTitle'),
          t('apiKeyDescription'),
          `${testIdPrefix}-mode-api-key`,
        )}
        {option(
          'subscription',
          <UserRoundCheck size={16} strokeWidth={2.2} />,
          t('subscriptionTitle'),
          t('subscriptionDescription'),
          `${testIdPrefix}-mode-subscription`,
        )}
      </div>
    </div>
  );
}
