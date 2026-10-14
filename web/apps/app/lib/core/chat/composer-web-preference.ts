/**
 * Chat web preference read/write for the composer / model options panel. The restored state and the switch callback in ChatView both go through here,
 * and tests drive it too, so the panel read and the send read are not copied twice.
 *
 * - Read: a draft session (no conversation id yet) reads the draft slot first, otherwise it follows the same ladder as sending (`displayCapabilityPreferences`),
 *   the relay default layer is supplied by `relayWebPreferenceDefaultFor`; when the identity is absent only the default layer is left.
 * - Write: a draft session writes the draft slot (moved to the conversation layer by `migrateDraftScopedModelControls` when sending creates the conversation), otherwise it writes the conversation layer.
 */
import type { AIModel, Provider } from '@oriveo/shared';
import {
  capabilityPreferenceIdentity,
  displayCapabilityPreferences,
  displayRelayWebPreference,
  relayWebPreferenceIdentity,
  loadCapabilityPreferenceDraft,
  saveCapabilityPreferenceDraft,
  saveCapabilityPreferences,
  type CapabilityPreferences,
  type CapabilityWebPreference,
} from './capability-preference-settings';
import { relayWebPreferenceDefaultFor } from './relay-web-probe-records';

export interface ComposerWebPreferenceScope {
  provider: Provider;
  model: AIModel;
  /** Id of the existing conversation; empty before a new conversation is sent. */
  conversationId: string | undefined;
  /** Draft session id of this page (constant for the lifetime of ChatView). */
  draftSessionId: string;
}

/** The web / thinking preference currently expressed in storage (restored-state read). The relay web switch uses the fixed identity, thinking levels still use the protocol-bearing identity. */
export function readComposerCapabilityPreferences(scope: ComposerWebPreferenceScope): CapabilityPreferences {
  const { provider, model, conversationId, draftSessionId } = scope;
  const identity = capabilityPreferenceIdentity(provider, model);
  const defaultWeb = relayWebPreferenceDefaultFor(provider, model);
  const values: CapabilityPreferences = identity
    ? loadCapabilityPreferenceDraft(!conversationId ? draftSessionId : undefined, identity)
      ?? displayCapabilityPreferences({ ...identity, conversationId, ...(defaultWeb ? { defaultWeb } : {}) })
    : { web: defaultWeb ?? 'off' };
  const relayIdentity = relayWebPreferenceIdentity(provider, model);
  if (!relayIdentity) return values;
  const web = (!conversationId ? loadCapabilityPreferenceDraft(draftSessionId, relayIdentity)?.web : undefined)
    ?? displayRelayWebPreference({ ...relayIdentity, conversationId, ...(defaultWeb ? { defaultWeb } : {}) });
  return { ...values, web };
}

/** The user toggles the web switch; returns false when the identity is absent (cannot be stored). The relay writes the fixed identity. */
export function writeComposerWebPreference(scope: ComposerWebPreferenceScope, next: CapabilityWebPreference): boolean {
  const { provider, model, conversationId, draftSessionId } = scope;
  const identity = relayWebPreferenceIdentity(provider, model) ?? capabilityPreferenceIdentity(provider, model);
  if (!identity) return false;
  const previous = displayCapabilityPreferences({ ...identity, conversationId });
  if (!conversationId) saveCapabilityPreferenceDraft(draftSessionId, identity, { ...previous, web: next });
  else saveCapabilityPreferences({ ...identity, scope: 'conversation_connection_model', conversationId }, { ...previous, web: next });
  return true;
}
