'use client';

import { useTranslations } from 'next-intl';
import {
  ArrowLeftRight,
  Check,
  ChevronRight,
  Cpu,
  Layers,
  LayoutGrid,
  Link2,
  SlidersHorizontal,
  Zap,
  type LucideIcon,
} from 'lucide-react';
import { ProviderIcon } from '../../../components/ProviderIcon';
import { resolveProviderWatermark } from '../../../components/providers/provider-brand-watermark';
import { useIsDarkTheme } from '../../../lib/hooks/useIsDarkTheme';
import styles from './ProviderCard.module.css';

/** Category filter on the setup page. */
export type ProviderCategory = 'all' | 'direct' | 'aggregators' | 'custom';

// Brand card colours. The glow, watermark, selected outline, selected name and check mark all use accent.
const CARD_COLORS: Record<string, { bg: string; darkBg: string; accent: string; darkAccent: string }> = {
  openAI:      { bg: '#ffffff', darkBg: '#1E2433', accent: '#10A37F', darkAccent: '#22C18D' },
  anthropic:   { bg: '#f4efe6', darkBg: '#2A2520', accent: '#C7956D', darkAccent: '#E0B58E' },
  gemini:      { bg: '#EDF3FF', darkBg: '#172038', accent: '#4285F4', darkAccent: '#7AB2FF' },
  openRouter:  { bg: '#EEEFFF', darkBg: '#1A1A30', accent: '#6D63FF', darkAccent: '#9B93FF' },
  deepseek:    { bg: '#EEF4FF', darkBg: '#15243B', accent: '#4F7BFF', darkAccent: '#7EA2FF' },
  grok:        { bg: '#F2F3F5', darkBg: '#1A1B1E', accent: '#0F0F10', darkAccent: '#F2F3F5' },
  mistral:     { bg: '#FFF3EC', darkBg: '#2D1A10', accent: '#FA500F', darkAccent: '#FF8205' },
  groq:        { bg: '#fff1ee', darkBg: '#2D1B18', accent: '#F55036', darkAccent: '#FF8A74' },
  togetherAI:  { bg: '#edf5ff', darkBg: '#152238', accent: '#0EA5E9', darkAccent: '#38BDF8' },
  fireworksAI: { bg: '#fff4ee', darkBg: '#2D1F18', accent: '#FF6B35', darkAccent: '#FF9B6B' },
  miniMax:     { bg: '#fff0f3', darkBg: '#2D1820', accent: '#E8457C', darkAccent: '#FF6B8A' },
  zhipu:       { bg: '#F0F0F2', darkBg: '#1A1B20', accent: '#333333', darkAccent: '#A0A0A8' },
  qwen:        { bg: '#EEEDFC', darkBg: '#1C1A38', accent: '#615CED', darkAccent: '#8B88F5' },
  moonshot:    { bg: '#EEF4FF', darkBg: '#142033', accent: '#2563EB', darkAccent: '#7DD3FC' },
  siliconFlow: { bg: '#F3ECFF', darkBg: '#1E1245', accent: '#7C3AED', darkAccent: '#A78BFA' },
};

const FALLBACK_COLORS = { bg: '#F4F4F5', darkBg: '#1E2028', accent: '#8B5CF6', darkAccent: '#A78BFA' };

// ProviderKind → tagline i18n key (pages.providerSetup.taglines.*)
const TAGLINE_KEY: Record<string, string> = {
  openAI: 'openai',
  anthropic: 'anthropic',
  gemini: 'gemini',
  deepseek: 'deepseek',
  grok: 'grok',
  mistral: 'mistral',
  miniMax: 'minimax',
  zhipu: 'zhipu',
  qwen: 'qwen',
  moonshot: 'moonshot',
  siliconFlow: 'siliconflow',
  openRouter: 'openrouter',
  groq: 'groq',
  togetherAI: 'together',
  fireworksAI: 'fireworks',
};

const useIsDark = useIsDarkTheme;

/* ── Crystal hero: jewel-like icon, title and subtitle ── */

export function SetupHero() {
  const t = useTranslations('pages.providerSetup');
  return (
    <div className={styles.hero}>
      <div className={styles.heroIconWrap}>
        <span className={styles.heroGlow} aria-hidden="true" />
        <span className={styles.heroIcon} aria-hidden="true">
          <Link2 size={26} strokeWidth={2.4} />
        </span>
      </div>
      <div className={styles.heroCopy}>
        <p className={styles.heroTitle}>{t('heroTitle')}</p>
        <p className={styles.heroSubtitle}>{t('heroSubtitle')}</p>
      </div>
    </div>
  );
}

/* ── Category chip bar: All / Direct / Aggregators / Custom ── */

const CATEGORY_ICON: Record<ProviderCategory, LucideIcon> = {
  all: LayoutGrid,
  direct: Zap,
  aggregators: Layers,
  custom: SlidersHorizontal,
};

const CATEGORY_LABEL_KEY: Record<ProviderCategory, string> = {
  all: 'categoryAll',
  direct: 'categoryDirect',
  aggregators: 'categoryAggregators',
  custom: 'categoryCustom',
};

const CATEGORIES: ProviderCategory[] = ['all', 'direct', 'aggregators', 'custom'];

export function ProviderCategoryChips({
  selected,
  onSelect,
}: {
  selected: ProviderCategory;
  onSelect: (category: ProviderCategory) => void;
}) {
  const t = useTranslations('pages.providerSetup');
  return (
    <div className={styles.chipBar}>
      <div className={styles.chipRow}>
        {CATEGORIES.map((category) => {
          const Icon = CATEGORY_ICON[category];
          const active = selected === category;
          return (
            <button
              key={category}
              type="button"
              className={styles.chip}
              data-active={active}
              onClick={() => onSelect(category)}
            >
              <Icon size={11} strokeWidth={2.4} aria-hidden="true" />
              <span>{t(CATEGORY_LABEL_KEY[category])}</span>
            </button>
          );
        })}
      </div>
    </div>
  );
}

/* ── Provider showcase card, laid out in a two-column grid ── */

interface ProviderShowcaseCardProps {
  kind: string;
  displayName: string;
  selected: boolean;
  isDark: boolean;
  onSelect: () => void;
}

export function ProviderShowcaseCard({ kind, displayName, selected, isDark, onSelect }: ProviderShowcaseCardProps) {
  const t = useTranslations('pages.providerSetup');
  const colors = CARD_COLORS[kind] ?? FALLBACK_COLORS;
  const watermark = resolveProviderWatermark(kind);
  const taglineKey = TAGLINE_KEY[kind];
  const tagline = taglineKey ? t(`taglines.${taglineKey}`) : null;

  return (
    <button
      type="button"
      className={styles.showcaseCard}
      data-selected={selected}
      onClick={onSelect}
      style={{
        '--card-bg': isDark ? colors.darkBg : colors.bg,
        '--card-accent': isDark ? colors.darkAccent : colors.accent,
      } as React.CSSProperties}
    >
      {/* Brand watermark: a brand-coloured silhouette bleeding off the bottom-right corner, carrying the identity instead of a flat colour fill */}
      {watermark?.type === 'mask' && (
        <span
          className={styles.cardWatermark}
          style={{ maskImage: `url(${watermark.asset})`, WebkitMaskImage: `url(${watermark.asset})` }}
          aria-hidden="true"
        />
      )}
      {watermark?.type === 'symbol' && (
        <span className={styles.cardWatermarkSymbol} aria-hidden="true">
          <watermark.Icon size={96} />
        </span>
      )}

      <span className={styles.cardTop}>
        <span className={styles.cardLogo}>
          <ProviderIcon kind={kind} size={28} />
        </span>
        {selected && (
          <span className={styles.cardCheck} aria-hidden="true">
            <Check size={11} strokeWidth={3.2} />
          </span>
        )}
      </span>

      <span className={styles.cardName}>{displayName}</span>
      {tagline && <span className={styles.cardTagline}>{tagline}</span>}
    </button>
  );
}

/* ── Showcase group: eyebrow heading plus a two-column grid ── */

export function ProviderShowcaseSection({
  label,
  providers,
  selectedKind,
  onSelect,
}: {
  label: string;
  providers: Array<{ kind: string; displayName: string }>;
  selectedKind: string | null;
  onSelect: (kind: string) => void;
}) {
  const isDark = useIsDark();
  if (providers.length === 0) return null;
  return (
    <section>
      <span className={styles.sectionEyebrow}>{label}</span>
      <div className={styles.showcaseGrid}>
        {providers.map((p) => (
          <ProviderShowcaseCard
            key={p.kind}
            kind={p.kind}
            displayName={p.displayName}
            selected={selectedKind === p.kind}
            isDark={isDark}
            onSelect={() => onSelect(p.kind)}
          />
        ))}
      </div>
    </section>
  );
}

/* ── Entry points under the Custom category: local compute and a custom relay endpoint ── */

export function CustomRelayEntry({ onTap }: { onTap: () => void }) {
  const t = useTranslations('pages.providerSetup');
  return (
    <CustomProviderEntry
      title={t('customEndpoint')}
      subtitle={t('relaySubtitle')}
      Icon={ArrowLeftRight}
      variant="endpoint"
      onTap={onTap}
    />
  );
}

export function LocalComputeEntry({ onTap }: { onTap: () => void }) {
  const t = useTranslations('pages.providerSetup');
  return (
    <CustomProviderEntry
      title={t('localCompute')}
      subtitle={t('localComputeSubtitle')}
      Icon={Cpu}
      variant="local"
      onTap={onTap}
    />
  );
}

function CustomProviderEntry({
  title,
  subtitle,
  Icon,
  variant,
  onTap,
}: {
  title: string;
  subtitle: string;
  Icon: LucideIcon;
  variant: 'local' | 'endpoint';
  onTap: () => void;
}) {
  const iconVariant = variant === 'local' ? styles.customEntryIconLocal : styles.customEntryIconEndpoint;
  return (
    <button type="button" className={styles.customEntry} onClick={onTap}>
      <span className={`${styles.customEntryIcon} ${iconVariant}`} aria-hidden="true">
        <Icon size={17} strokeWidth={2.4} />
      </span>
      <span className={styles.customEntryInfo}>
        <span className={styles.customEntryTitle}>{title}</span>
        <span className={styles.customEntrySubtitle}>{subtitle}</span>
      </span>
      <ChevronRight size={14} strokeWidth={2.4} className={styles.customEntryChevron} aria-hidden="true" />
    </button>
  );
}
