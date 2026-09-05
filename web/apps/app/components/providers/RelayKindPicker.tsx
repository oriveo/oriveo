'use client';

import type { CSSProperties, ReactNode } from 'react';
import { CheckCircle2, SlidersHorizontal } from 'lucide-react';
import { useTranslations } from 'next-intl';
import type { RelayKind } from '@oriveo/shared';
import { ProviderIcon } from '../ProviderIcon';
import styles from './RelayKindPicker.module.css';

/**
 * Logo strategy for the left side of each card:
 * - the three standard protocols use their real brand logo (OpenAI / Anthropic / Gemini PNGs under /providers/)
 * - the Codex style reuses the OpenAI logo, since Responses compatibility is still OpenAI; the accent color carries the difference
 * - fully custom relays have no brand, so they fall back to SlidersHorizontal on a soft borderless background
 */
type LogoSpec =
  | { type: 'provider'; kind: string }
  | { type: 'gradient'; icon: typeof SlidersHorizontal };

type BadgeSpec = 'default' | 'advanced';

export const RELAY_KIND_OPTIONS: Array<{
  kind: RelayKind;
  accent: string;
  logo: LogoSpec;
  titleKey: string;
  descKey: string;
  /** Protocol path chip, such as "/v1/chat/completions". Not localized. */
  endpointPath?: string;
  /** Badge beside the title: 'default' marks the recommended OpenAI-compatible option, 'advanced' marks Custom. */
  badge?: BadgeSpec;
}> = [
  {
    kind: 'openai_compatible',
    accent: '#10a37f',
    logo: { type: 'provider', kind: 'openAI' },
    titleKey: 'kind.openai.title',
    descKey: 'kind.openai.desc',
    endpointPath: '/v1/chat/completions',
    badge: 'default',
  },
  {
    kind: 'codex_style',
    accent: '#2563eb',
    logo: { type: 'provider', kind: 'openAI' },
    titleKey: 'kind.codex.title',
    descKey: 'kind.codex.desc',
    endpointPath: '/v1/responses',
  },
  {
    kind: 'anthropic_compatible',
    accent: '#c7956d',
    logo: { type: 'provider', kind: 'anthropic' },
    titleKey: 'kind.anthropic.title',
    descKey: 'kind.anthropic.desc',
  },
  {
    kind: 'gemini_compatible',
    accent: '#4285f4',
    logo: { type: 'provider', kind: 'gemini' },
    titleKey: 'kind.gemini.title',
    descKey: 'kind.gemini.desc',
  },
  {
    kind: 'custom',
    accent: '#64748b',
    logo: { type: 'gradient', icon: SlidersHorizontal },
    titleKey: 'kind.custom.title',
    descKey: 'kind.custom.desc',
    badge: 'advanced',
  },
];

interface RelayKindPickerProps {
  selectedKind: RelayKind;
  onSelect: (kind: RelayKind) => void;
  includeCustom?: boolean;
}

function LogoBox({ logo }: { logo: LogoSpec }): ReactNode {
  if (logo.type === 'provider') {
    return (
      <span className={styles.logoBrand} aria-hidden="true">
        <ProviderIcon kind={logo.kind} size={30} bare />
      </span>
    );
  }
  const Icon = logo.icon;
  return (
    <span className={styles.logoGradient} aria-hidden="true">
      <Icon size={18} strokeWidth={2.4} />
    </span>
  );
}

export function RelayKindPicker({ selectedKind, onSelect, includeCustom = true }: RelayKindPickerProps) {
  const t = useTranslations('pages.relaySetup');

  return (
    <div className={styles.grid}>
      {RELAY_KIND_OPTIONS.filter((option) => includeCustom || option.kind !== 'custom').map((option) => {
        const selected = selectedKind === option.kind;
        return (
          <button
            key={option.kind}
            type="button"
            className={styles.card}
            data-selected={selected}
            data-kind={option.kind}
            style={{ '--kind-accent': option.accent } as CSSProperties}
            onClick={() => onSelect(option.kind)}
            aria-pressed={selected}
          >
            <LogoBox logo={option.logo} />
            <span className={styles.copy}>
              <span className={styles.titleRow}>
                <span className={styles.title}>{t(option.titleKey)}</span>
                {option.badge === 'default' && (
                  <span className={styles.badgeDefault}>{t('kind.defaultBadge')}</span>
                )}
                {option.badge === 'advanced' && (
                  <span className={styles.badgeAdvanced}>{t('kind.advancedBadge')}</span>
                )}
              </span>
              <span className={styles.desc}>{t(option.descKey)}</span>
              {option.endpointPath && (
                <span className={styles.endpointChip}>{option.endpointPath}</span>
              )}
            </span>
            <CheckCircle2 className={styles.check} size={18} strokeWidth={2.2} aria-hidden="true" />
          </button>
        );
      })}
    </div>
  );
}
