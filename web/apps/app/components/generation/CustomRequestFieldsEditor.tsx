'use client';

import { useEffect, useMemo, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import type { AIModel, Provider } from '@oriveo/shared';
import { previewSafeCustomFragment, safeCustomDeclaredOwners } from '@oriveo/core/providers/request-builders/dispatch';
import { resolveCustomControlDefinitions } from '@oriveo/core/providers/request-preference/capability-runtime';
import { getCapabilityRuntime } from '../../lib/core/metadata/metadata-client';
import { capabilityRuntimeIdentity } from '../../lib/core/chat/capability-preference-settings';
import { resolveGenerationProfileForModel } from '../../lib/core/chat/stream-options';
import {
  CUSTOM_FRAGMENT_OWNERS,
  customFragmentOwnerFacts,
  customFragmentScope,
  forwardPortCustomFragmentsIfNeeded,
  loadCustomFragmentSettings,
  saveCustomFragmentSettings,
  type CustomFragmentOwner,
} from '../../lib/core/chat/custom-fragment-settings';
import styles from './GenerationParameterPanel.module.css';

// The rule lives in `lib/core/chat/custom-fragment-rejection`, because the error card uses the
// same three-way classification. Re-exported here so existing importers keep their paths.
import { customFragmentRejectionMessage } from '../../lib/core/chat/custom-fragment-rejection';
export { customFragmentRejectionMessage };
export type { CustomFragmentRejection } from '../../lib/core/chat/custom-fragment-rejection';

/**
 * Custom request fields editor (Advanced settings -> Developer -> Custom request fields).
 *
 * The page carries every owner for one connection x model x transport at once, split into
 * sections per owner, rather than handling one owner behind a global switch:
 * - an entry point inside the three capability cards would put a very rare escape hatch at the
 *   same level as high-frequency controls;
 * - a separate automatic/custom radio lets a fully filled editor sit there without taking
 *   effect, and the user cannot tell a bad payload from an unset switch.
 *
 * The path is panel -> advanced settings -> developer -> this page, so depth tracks frequency,
 * and mode is derived entirely from content: non-empty = active, cleared = off, with no third
 * state in between.
 */
export function CustomRequestFieldsEditor({ provider, model }: {
  provider: Provider;
  model: AIModel;
  /**
   * Kept only as call-site context; it takes no part in any copy or storage decision.
   *
   * The custom field key is connection x model x transport x owner (see `storageKey` in
   * `custom-fragment-settings`) and has no conversation dimension, so an edit made from the chat
   * page and one made from the provider detail page hit the same record. Scope wording and the
   * delete confirmation therefore always use the connection_model variant: saying "this
   * conversation" would suggest that leaving the conversation reverts the change, when what was
   * edited is the default for that model in every conversation.
   */
  conversationId?: string;
}) {
  const tc = useTranslations('common');
  const transportIdentity = capabilityRuntimeIdentity(provider, model)?.transportIdentity ?? '';
  const runtime = getCapabilityRuntime();
  /** The relay generation field structure comes from the locally parsed profile, not from official controlDefinitions. */
  const generationProfile = provider.kind === 'relay'
    ? resolveGenerationProfileForModel(provider, model)
    : undefined;

  const identityKey = `${provider.id}\u0000${model.id}\u0000${transportIdentity}`;
  /**
   * Sections and schema are frozen the moment the page opens, for two reasons: clearing the
   * content should not make a whole section vanish while the user is still editing it and take
   * focus with it; and deciding the schema means parsing metadata, which inside render would run
   * three times a frame. A new snapshot is taken only when connection x model x transport really
   * changes, which is a different configuration anyway.
   */
  const [snapshot, setSnapshot] = useState(() => loadSnapshot(provider, model, transportIdentity));
  /**
   * Starting at `null` is deliberate: the lazy forward-port must not run during render, because
   * it writes to storage and broadcasts an event. The first-paint snapshot therefore only reads;
   * the port itself runs on the first execution of the effect below, after which a fresh
   * snapshot is taken. The cost is one extra render on mount, which buys not mutating global
   * state inside a render function -- concurrent rendering may run that twice and is entitled to
   * discard one of the results.
   */
  const loadedKey = useRef<string | null>(null);
  useEffect(() => {
    if (loadedKey.current === identityKey) return;
    loadedKey.current = identityKey;
    // Loading is a discrete event: run the lazy forward-port once, then take the snapshot.
    // Without it, a server recipe change (same transport, only runtimeRevision moves) would leave
    // this page blank although the user changed nothing. A draft written under an older revision
    // carries over and is revalidated against the new recipe; if it fails validation the owner is
    // deactivated and the raw text is kept, so the user can still edit it.
    if (transportIdentity) forwardPortCustomFragmentsIfNeeded({ provider, model, transportIdentity });
    setSnapshot(loadSnapshot(provider, model, transportIdentity));
  }, [identityKey, model, provider, transportIdentity]);

  const [drafts, setDrafts] = useState<Record<string, string>>(snapshot.drafts);
  const [legacyEmptyOwners, setLegacyEmptyOwners] = useState<Set<string>>(snapshot.legacyEmptyOwners);
  const [pendingRemoval, setPendingRemoval] = useState<CustomFragmentOwner | null>(null);
  useEffect(() => {
    setDrafts(snapshot.drafts);
    setLegacyEmptyOwners(snapshot.legacyEmptyOwners);
    setPendingRemoval(null);
  }, [snapshot]);

  /**
   * mode is derived from content: non-empty = custom (active), cleared = automatic (off). The one
   * exception is a stored "custom with empty content", which has to stay custom, or the red
   * warning on that section would disappear before the user has dealt with it.
   */
  const persist = (owner: CustomFragmentOwner, raw: string, keepLegacyCustom: boolean) => {
    saveCustomFragmentSettings(
      customFragmentScope(provider, model, transportIdentity, owner),
      { configurationMode: raw.trim() || keepLegacyCustom ? 'custom' : 'auto', raw },
    );
  };

  const setDraft = (owner: CustomFragmentOwner, raw: string) => {
    setDrafts((current) => ({ ...current, [owner]: raw }));
    // Drafts are persisted as they are typed; requiring an explicit apply would drop 30 lines of JSON when the panel closes.
    persist(owner, raw, legacyEmptyOwners.has(owner));
  };

  const disarmLegacy = (owner: CustomFragmentOwner) => {
    setLegacyEmptyOwners((current) => {
      const next = new Set(current);
      next.delete(owner);
      return next;
    });
    persist(owner, drafts[owner] ?? '', false);
  };

  const scopeNote = tc('customRequestFieldsScopeConnectionModel');

  return (
    <section className={styles.customFields} data-testid="custom-request-fields">
      {snapshot.sections.length === 0 ? (
        <p className={styles.customHint} data-testid="custom-fields-empty">
          {tc('customRequestFieldsNoSchemaForModel')}
        </p>
      ) : snapshot.sections.map((owner) => {
        const raw = drafts[owner] ?? '';
        const trimmed = raw.trim();
        const isLegacyEmpty = !trimmed && legacyEmptyOwners.has(owner);
        const definitions = ownerDefinitions(runtime, model, owner);
        const relayGenerationProfile = owner === 'generation' ? generationProfile : undefined;
        const preview = trimmed
          ? previewSafeCustomFragment({
            raw,
            owner,
            generationProfile: relayGenerationProfile,
            recipes: [],
            intents: {},
            ...(definitions.length > 0
              ? { declaredOwners: Object.fromEntries(definitions.map((definition) => [definition.targetPointer, owner])) }
              : {}),
          })
          : undefined;
        const allowedPaths = definitions.length > 0
          ? definitions.map((definition) => definition.targetPointer)
          : Object.keys(safeCustomDeclaredOwners(relayGenerationProfile));
        const docsUrl = officialCustomFieldDocsUrl(runtime, definitions.flatMap((definition) => definition.sourceRefs));
        const inputID = `custom-fragment-${owner}-${model.id}`;

        return (
          <div key={owner} className={styles.customOwner} data-testid={`custom-fields-${owner}`}>
            <div className={styles.customOwnerHeader}>
              {/* Section titles use the user-facing words rather than web / reasoning / generation:
                  the reader is a developer, but still arrives through the search / thinking /
                  parameters concepts. */}
              <strong>{tc(OWNER_TITLE_KEYS[owner])}</strong>
              {/* "In use" is the only status statement in a section -- mode is derived from content, there is no second switch to look at. */}
              {trimmed && <span className={styles.customOwnerState}>{tc('customRequestFieldsInUse')}</span>}
            </div>

            {!snapshot.schemaOwners.has(owner) && (
              <p className={styles.customHint}>{tc('customRequestFieldsNoSchemaForControl')}</p>
            )}

            {/* A stored "custom with empty content" still fails closed on the outbound path, so
                the page has to say so; otherwise the user only sees the send fail while this page
                looks like nothing is configured. */}
            {isLegacyEmpty && (
              <>
                <p className={styles.customDanger} data-testid={`custom-fields-legacy-${owner}`}>
                  {tc('customRequestFieldsLegacyEmpty')}
                </p>
                <button type="button" className={styles.customDangerAction} onClick={() => disarmLegacy(owner)}>
                  {tc('customRequestFieldsSwitchBackToAutomatic')}
                </button>
              </>
            )}

            <textarea
              id={inputID}
              className={styles.customTextarea}
              dir="ltr"
              spellCheck={false}
              value={raw}
              aria-label={tc('customRequestFieldsJsonLabel')}
              aria-describedby={`${inputID}-hint`}
              aria-invalid={Boolean(preview && !preview.accepted)}
              onChange={(event) => setDraft(owner, event.target.value)}
            />

            {!preview && (
              <p id={`${inputID}-hint`} className={styles.customHint}>{tc('customRequestFieldsPreviewHint')}</p>
            )}
            {preview && !preview.accepted && (() => {
              const message = customFragmentRejectionMessage(preview.reason, allowedPaths);
              return (
                <p id={`${inputID}-hint`} className={styles.customDanger} data-testid={`custom-fields-error-${owner}`}>
                  {message.values ? tc(message.key, message.values) : tc(message.key)}
                </p>
              );
            })()}
            {preview?.accepted && (
              <>
                <p id={`${inputID}-hint`} className={styles.customHint}>{tc('customRequestFieldsPreview')}</p>
                <pre className={styles.customPreview} aria-label={tc('customRequestFieldsPreview')}>
                  {preview.pointers.map((pointer) => `${pointer}: <redacted>`).join('\n')}
                </pre>
              </>
            )}

            {/* The cost and privacy tier come from the server as controlDefinitions.riskTier; the client does not guess. */}
            {customFragmentOwnerFacts({ provider, model, transportIdentity, owner }).riskTiers.map((tier) => (
              <p key={tier} className={styles.customHint} data-capability-risk={tier}>
                {tc(tier === 'privacy_impacting' ? 'capabilityRiskPrivacy' : 'capabilityRiskCost')}
              </p>
            ))}

            {docsUrl ? (
              <p className={styles.customHint}>
                <a href={docsUrl} target="_blank" rel="noreferrer">{tc('customRequestFieldsDocs')}</a>
              </p>
            ) : provider.kind === 'relay' ? (
              <p className={styles.customHint}>{tc('customRequestFieldsRelayDocs')}</p>
            ) : null}

            {/* There is only one scope: this model plus transport under this connection (see the `conversationId` comment at the top of the component). */}
            <p className={styles.customHint}>{scopeNote}</p>

            {pendingRemoval === owner ? (
              <div className={styles.customRemoveConfirm} role="group" aria-label={tc('customRequestFieldsRemoveTitle')}>
                <p className={styles.customHint}>
                  {tc('customRequestFieldsDeleteConnection', { owner: tc(OWNER_TITLE_KEYS[owner]) })}
                </p>
                <button type="button" onClick={() => setPendingRemoval(null)}>
                  {tc('customRequestFieldsRemoveKeep')}
                </button>
                <button
                  type="button"
                  className={styles.customDangerAction}
                  onClick={() => {
                    setDrafts((current) => ({ ...current, [owner]: '' }));
                    setLegacyEmptyOwners((current) => {
                      const next = new Set(current);
                      next.delete(owner);
                      return next;
                    });
                    persist(owner, '', false);
                    setPendingRemoval(null);
                  }}
                >{tc('customRequestFieldsRemoveConfirm')}</button>
              </div>
            ) : (
              <button
                type="button"
                className={styles.customDangerAction}
                disabled={!trimmed && !isLegacyEmpty}
                onClick={() => setPendingRemoval(owner)}
              >{tc('customRequestFieldsRemoveConfirm')}</button>
            )}
          </div>
        );
      })}
      <p className={styles.customHint} data-testid="custom-fields-footer">{tc('customRequestFieldsFooter')}</p>
    </section>
  );
}

/** Section order is fixed as web -> reasoning -> generation, matching the card order in the panel. */
const OWNER_TITLE_KEYS: Record<CustomFragmentOwner, string> = {
  web: 'capabilityControlWebSearch',
  reasoning: 'capabilityControlThinking',
  generation: 'generationParameters',
};

function ownerDefinitions(
  runtime: ReturnType<typeof getCapabilityRuntime>,
  model: AIModel,
  owner: CustomFragmentOwner,
) {
  return runtime
    ? resolveCustomControlDefinitions(owner, model.capabilityControls?.[owner], runtime.controlDefinitions, runtime.sourceIndex)
    : [];
}

/**
 * Visible owners = has a schema, union stored content, union stored empty custom. The second and
 * third sets cannot be dropped: the schema comes from the server and may disappear on a metadata
 * refresh while the user's configuration is still in effect (the outbound path only looks at the
 * configuration itself). Hiding the section as soon as the schema goes would take away the only
 * way to switch it off.
 */
/**
 * Read-only: no writes, no broadcast. It is also called from the lazy initializer of `useState`
 * during render, which is why the forward-port stays in the caller's effect instead of moving in
 * here (see the `loadedKey` comment in the component).
 */
function loadSnapshot(provider: Provider, model: AIModel, transportIdentity: string) {
  const sections: CustomFragmentOwner[] = [];
  const schemaOwners = new Set<CustomFragmentOwner>();
  const legacyEmptyOwners = new Set<string>();
  const drafts: Record<string, string> = {};
  for (const owner of CUSTOM_FRAGMENT_OWNERS) {
    const settings = loadCustomFragmentSettings(customFragmentScope(provider, model, transportIdentity, owner));
    drafts[owner] = settings.raw;
    const hasContent = settings.raw.trim().length > 0;
    if (settings.configurationMode === 'custom' && !hasContent) legacyEmptyOwners.add(owner);
    const { hasSchema } = customFragmentOwnerFacts({ provider, model, transportIdentity, owner });
    if (hasSchema) schemaOwners.add(owner);
    if (hasSchema || hasContent || legacyEmptyOwners.has(owner)) sections.push(owner);
  }
  return { sections, schemaOwners, legacyEmptyOwners, drafts };
}

function officialCustomFieldDocsUrl(runtime: ReturnType<typeof getCapabilityRuntime>, refs: readonly string[]): string | undefined {
  for (const ref of refs) {
    const source = runtime?.sourceIndex?.[ref];
    if (!source || typeof source !== 'object' || Array.isArray(source)) continue;
    const candidate = (source as Record<string, unknown>).officialUrl ?? (source as Record<string, unknown>).url;
    if (typeof candidate === 'string' && /^https:\/\//.test(candidate)) return candidate;
  }
  return undefined;
}
