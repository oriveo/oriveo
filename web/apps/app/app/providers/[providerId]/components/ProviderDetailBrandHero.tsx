'use client';

import { useMemo, type CSSProperties } from 'react';
import { useTranslations } from 'next-intl';
import { ChevronRight, KeyRound, MessageSquarePlus, Pencil, RefreshCw, UserRoundCheck } from 'lucide-react';
import type { Provider } from '@oriveo/shared';
import { ProviderIcon } from '../../../../components/ProviderIcon';
import { PROVIDER_BRAND_COLORS } from '../../../../lib/constants/provider-brand-colors';
import { getProviderInstanceDisplayName } from '../../../../lib/core/providers/provider-display';
import { getEffectiveStatusKind, type EffectiveStatusKind } from '../../../../lib/core/providers/provider-status';
import { resolveProviderWatermark } from '../../../../components/providers/provider-brand-watermark';
import styles from './ProviderDetailBrandHero.module.css';

interface ProviderDetailBrandHeroProps {
  provider: Provider;
  onStartChat?: () => void;
  onVerifyConnection?: () => void;
  resyncLabel?: string;
  onEditApiKey?: () => void;
  onEditName?: () => void;
  isSyncing?: boolean;
}

// Compress a vivid brand color into a muted, understated tone.
function hsbAdjusted(hex: string, sat: number, val: number): string {
  const cleaned = hex.replace('#', '');
  const r = parseInt(cleaned.substring(0, 2), 16) / 255;
  const g = parseInt(cleaned.substring(2, 4), 16) / 255;
  const b = parseInt(cleaned.substring(4, 6), 16) / 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const d = max - min;
  let h = 0;
  if (d !== 0) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  const s = max === 0 ? 0 : d / max;
  const v = max;
  const ns = Math.max(0, Math.min(1, s * sat));
  const nv = Math.max(0, Math.min(1, v * val));
  const c = nv * ns;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = nv - c;
  let nr = 0, ng = 0, nb = 0;
  if (h < 60) { nr = c; ng = x; nb = 0; }
  else if (h < 120) { nr = x; ng = c; nb = 0; }
  else if (h < 180) { nr = 0; ng = c; nb = x; }
  else if (h < 240) { nr = 0; ng = x; nb = c; }
  else if (h < 300) { nr = x; ng = 0; nb = c; }
  else { nr = c; ng = 0; nb = x; }
  const toHex = (n: number) => Math.round((n + m) * 255).toString(16).padStart(2, '0');
  return `#${toHex(nr)}${toHex(ng)}${toHex(nb)}`;
}

function formatRelativeTimeShort(iso: string | undefined, neverLabel: string, t: ReturnType<typeof useTranslations>): string {
  if (!iso) return neverLabel;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return neverLabel;
  const diff = Date.now() - d.getTime();
  const mins = Math.floor(diff / 60_000);
  if (mins < 1) return t('justNow');
  if (mins < 60) return t('minutesAgo', { count: mins });
  const hours = Math.floor(mins / 60);
  if (hours < 24) return t('hoursAgo', { count: hours });
  return d.toLocaleDateString();
}

function statusLabel(
  kind: EffectiveStatusKind,
  tc: ReturnType<typeof useTranslations>,
  t: ReturnType<typeof useTranslations>,
): string {
  switch (kind) {
    case 'connected': return tc('connected');
    case 'syncing': return tc('syncing');
    case 'issue': return tc('issue');
    case 'needsKey': return t('needsApiKey');
  }
}

export function ProviderDetailBrandHero({
  provider,
  onStartChat,
  onVerifyConnection,
  resyncLabel,
  onEditApiKey,
  onEditName,
  isSyncing,
}: ProviderDetailBrandHeroProps) {
  const t = useTranslations('pages.providerDetail');
  const tHero = useTranslations('pages.providerDetail.hero');
  const tList = useTranslations('pages.providerList');
  const tc = useTranslations('common');

  const displayName = getProviderInstanceDisplayName(provider);
  const effectiveKind = getEffectiveStatusKind(provider);
  const isRelay = provider.kind === 'relay';
  const allowsCredentialEditing = true;

  // Brand color: the same hsbAdjusted treatment as ProviderHeroCard; relay falls back to the primary purple.
  const brandPair = PROVIDER_BRAND_COLORS[provider.kind] ?? PROVIDER_BRAND_COLORS.relay;
  const rawBrand = isRelay ? '#8C5FF8' : brandPair.light;
  const subduedBrand = hsbAdjusted(rawBrand, 0.62, 0.88);

  const enabledCount = provider.models.length;

  const syncedText = formatRelativeTimeShort(provider.lastCheckedAt, tHero('syncedNever'), tList);

  // This row is not a key on the subscription path. Dispatch on kind rather than on authMode
  // alone: each path has its own copy, and "Signed in with ChatGPT" and "Signed in with x.ai"
  // refer to two different account systems.
  const isSubscription = provider.authMode === 'subscription';
  const isOpenAISubscription = isSubscription && provider.kind === 'openAI';

  // API key row value: no key -> tapToSet; a preview -> the preview; older data without a preview -> tapToView/Set.
  const apiKeyDisplay = useMemo(() => {
    // Showing a masked string in the subscription state suggests a key is still stored, and
    // tapping it only offers re-authorization; the title and the value change together so the
    // row matches its behavior.
    if (isSubscription) {
      return isOpenAISubscription ? tHero('signedInWithChatGPT') : tHero('signedInWithXAI');
    }
    if (effectiveKind === 'needsKey') return tHero('tapToSet');
    if (provider.apiKeyPreview) return provider.apiKeyPreview;
    return provider.status.kind === 'issue' ? tHero('tapToSet') : tHero('tapToView');
  }, [isSubscription, isOpenAISubscription, effectiveKind, provider.apiKeyPreview, provider.status.kind, tHero]);
  // In the subscription state the value is a real status sentence rather than a "not filled in yet"
  // placeholder, so it must not be dimmed.
  const apiKeyDimmed = !isSubscription && !provider.apiKeyPreview;

  // Official providers with a transparent logo use a masked silhouette; Relay and a user-owned provider use the motif symbol.
  const watermark = resolveProviderWatermark(provider.kind);

  // Chat can only start when a default model exists.
  const canStartChat = provider.models.some((m) => m.isDefault) || provider.models.length > 0;
  const supportsResync = !isRelay; // Relay liveness checks happen on the relay editor page, so the detail page shows no Verify action.

  const showsActionSection = (canStartChat && Boolean(onStartChat)) || (supportsResync && Boolean(onVerifyConnection));

  return (
    <section
      className={styles.card}
      style={{ ['--brand-color' as never]: subduedBrand } as CSSProperties}
      data-status={effectiveKind}
    >
      {watermark?.type === 'mask' && (
        <span
          className={styles.watermark}
          style={{
            maskImage: `url(${watermark.asset})`,
            WebkitMaskImage: `url(${watermark.asset})`,
          }}
          aria-hidden="true"
        />
      )}
      {watermark?.type === 'symbol' && (
        <span className={styles.watermarkSymbol} aria-hidden="true">
          <watermark.Icon size={164} />
        </span>
      )}

      {/* Top row: logo badge + status capsule */}
      <div className={styles.topRow}>
        <span className={styles.logoBadge} aria-hidden="true">
          <ProviderIcon
            kind={provider.kind}
            size={36}
            bare
            relayKind={provider.relayKind}
            providerName={displayName}
            baseURLText={provider.baseURLText}
            forceDark
          />
        </span>

        <span className={styles.statusCapsule} data-status={effectiveKind}>
          <span className={styles.statusDot} aria-hidden="true" />
          <span>{statusLabel(effectiveKind, tc, t)}</span>
        </span>
      </div>

      {/* Name + meta */}
      <div className={styles.nameBlock}>
        <div className={styles.nameRow}>
          <h1 className={styles.name}>{displayName}</h1>
          {onEditName && (
            <button
              type="button"
              className={styles.editNameBtn}
              onClick={onEditName}
              aria-label={tHero('editName')}
            >
              <Pencil size={13} strokeWidth={2.4} aria-hidden="true" />
            </button>
          )}
        </div>
        <div className={styles.metaRow}>
          <span className={styles.metaCount}>
            {tHero('availableModelsCount', { count: enabledCount })}
          </span>
          <span className={styles.metaDot} aria-hidden="true" />
          <span className={styles.metaSynced} suppressHydrationWarning>{syncedText}</span>
        </div>
      </div>

      {/* API Key glass capsule */}
      {allowsCredentialEditing && onEditApiKey && (
        <button
          type="button"
          className={styles.apiKeyRow}
          onClick={onEditApiKey}
          aria-label={isSubscription ? t('subscription') : t('apiKey')}
          data-testid={isSubscription ? 'hero-subscription-row' : 'hero-api-key-row'}
        >
          <span className={styles.apiKeyIcon} aria-hidden="true">
            {isSubscription
              ? <UserRoundCheck size={13} strokeWidth={2.4} />
              : <KeyRound size={13} strokeWidth={2.4} />}
          </span>
          <span className={styles.apiKeyLabelStack}>
            <span className={styles.apiKeyLabel}>{isSubscription ? t('subscription') : t('apiKey')}</span>
            <span className={styles.apiKeyValue} data-dim={apiKeyDimmed ? 'true' : undefined}>
              {apiKeyDisplay}
            </span>
          </span>
          <ChevronRight className={styles.apiKeyChevron} size={14} strokeWidth={2.4} aria-hidden="true" />
        </button>
      )}

      {/* Actions */}
      {showsActionSection && (
        <div className={styles.actions}>
          {canStartChat && onStartChat && (
            <button type="button" className={styles.primaryAction} onClick={onStartChat}>
              <MessageSquarePlus size={14} strokeWidth={2.4} aria-hidden="true" />
              <span>{tHero('newChat')}</span>
            </button>
          )}
          {supportsResync && onVerifyConnection && (
            <button
              type="button"
              className={styles.secondaryAction}
              onClick={onVerifyConnection}
              disabled={isSyncing}
            >
              <RefreshCw
                size={13}
                strokeWidth={2.4}
                aria-hidden="true"
                className={isSyncing ? styles.spinningIcon : undefined}
              />
              <span>{isSyncing ? tc('syncing') : (resyncLabel ?? tHero('verifyConnection'))}</span>
            </button>
          )}
        </div>
      )}
    </section>
  );
}
