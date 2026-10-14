'use client';

/**
 * Minimal host for the modelOptions shot page (dev route only): mounts the production ModelOptionsPopover (expanded) directly,
 * with props computed by the same production functions as ChatView -> InputComposer (capability presentation, preference identity, relay default layer, display read),
 * and the preference switch writes the connection x model layer as production does; no production code is changed and no panel view state is hand-built.
 */
import { useCallback, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAppStore } from '../../../providers/StoreProvider';
import { ModelOptionsPopover } from '../../../components/chat/ModelOptionsPopover';
import { presentCapabilityControl } from '../../../lib/core/chat/capability-control-presentation';
import {
  capabilityPreferenceIdentity,
  displayCapabilityPreferences,
  displayRelayWebPreference,
  relayWebPreferenceIdentity,
  saveCapabilityPreferences,
  type CapabilityWebPreference,
} from '../../../lib/core/chat/capability-preference-settings';
import { relayWebPreferenceDefaultFor } from '../../../lib/core/chat/relay-web-probe-records';
import { relayDetailPageQuery } from '../../providers/[providerId]/relay-detail-nav';

/** The production panel uses the composer as its positioning container (absolutely positioned against its top edge); here a container of the same width sits at the bottom of the viewport. */
const COMPOSER_FRAME = { position: 'fixed', insetInline: 0, bottom: 24 } as const;
const COMPOSER_BOX = { position: 'relative', maxWidth: 820, height: 54, margin: '0 auto' } as const;

export function RelayModelOptionsHost({ providerId, modelId }: { providerId: string; modelId: string }) {
  const router = useRouter();
  const providers = useAppStore((s) => s.providers);
  const provider = providers.find((item) => item.id === providerId);
  const model = provider?.models.find((item) => item.id === modelId);
  const identity = useMemo(() => (provider && model ? capabilityPreferenceIdentity(provider, model) : null), [provider, model]);
  const webControl = useMemo(() => presentCapabilityControl(provider, model, 'web'), [provider, model]);
  const reasoningControl = useMemo(() => presentCapabilityControl(provider, model, 'reasoning'), [provider, model]);
  // Same read as ChatView readStoredWebIntent: relay default layer + the first layer that has a stored value.
  const readWebPreference = useCallback((): CapabilityWebPreference => {
    if (!provider || !model) return 'off';
    const defaultWeb = relayWebPreferenceDefaultFor(provider, model);
    // The relay web switch reads the fixed identity.
    const webIdentity = relayWebPreferenceIdentity(provider, model) ?? identity;
    return webIdentity
      ? displayRelayWebPreference({ ...webIdentity, ...(defaultWeb ? { defaultWeb } : {}) })
      : defaultWeb ?? 'off';
  }, [identity, model, provider]);
  const [webPreference, setWebPreference] = useState<CapabilityWebPreference>(readWebPreference);

  const onWebPreferenceChange = useCallback((next: CapabilityWebPreference) => {
    const webIdentity = provider && model ? relayWebPreferenceIdentity(provider, model) ?? identity : identity;
    if (!webIdentity) return;
    saveCapabilityPreferences({ ...webIdentity, scope: 'connection_model' }, { ...displayCapabilityPreferences(webIdentity), web: next });
    setWebPreference(readWebPreference());
  }, [identity, model, provider, readWebPreference]);

  return (
    <div style={COMPOSER_FRAME}>
      <div style={COMPOSER_BOX}>
        <ModelOptionsPopover
          provider={provider}
          model={model}
          webControl={webControl}
          reasoningControl={reasoningControl}
          webPreference={webPreference}
          onWebPreferenceChange={onWebPreferenceChange}
          transportIdentity={identity?.transportIdentity}
          onOpenRelayModelAdvanced={provider && model
            ? () => router.push(`/providers/${provider.id}${relayDetailPageQuery({ view: 'advanced', modelID: model.id, readOnly: false })}`)
            : undefined}
          onClose={() => {}}
        />
      </div>
    </div>
  );
}
