/**
 * Chat web preference read/write for the composer / model options panel. The restored state and the switch callback in ChatView both go through here,
 * and tests drive it too, so the panel read and the send read are not copied twice.
 *
 * - Read: a draft session (no conversation id yet) reads the draft slot first, otherwise it follows the same ladder as sending (`displayCapabilityPreferences`),
 *   the relay default layer is supplied by `relayWebPreferenceDefaultFor`; when the identity is absent only the default layer is left.
 * - Write: a draft session writes the draft slot (moved to the conversation layer by `migrateDraftScopedModelControls` when sending creates the conversation), otherwise it writes the conversation layer;
 *   both the web and the thinking switches go through here, and each call changes only its own item.
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
  withCapabilityReasoningIntent,
  type CapabilityPreferences,
  type CapabilityRuntimeIdentity,
  type CapabilityWebPreference,
} from './capability-preference-settings';
import type { ReasoningIntent } from '@oriveo/core/providers/request-preference/types';
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

/**
 * Change one item in a slot and keep the rest. For a draft session the "previous" value must be read
 * from the draft slot itself: the web and thinking switches write the same slot of the same identity,
 * and reading only the conversation ladder (a draft has no conversation layer yet) would reset the
 * other item to its default, so after the first send migrates the draft the restored state would read
 * back the clobbered copy (turn thinking on, then web on, and thinking switches itself off a turn later).
 */
function patchComposerSlot(
  scope: ComposerWebPreferenceScope,
  identity: CapabilityRuntimeIdentity,
  patch: (previous: CapabilityPreferences) => CapabilityPreferences,
  defaultWeb?: CapabilityWebPreference,
): void {
  const { conversationId, draftSessionId } = scope;
  const previous = (!conversationId ? loadCapabilityPreferenceDraft(draftSessionId, identity) : undefined)
    ?? displayCapabilityPreferences({ ...identity, conversationId, ...(defaultWeb ? { defaultWeb } : {}) });
  const next = patch(previous);
  if (!conversationId) saveCapabilityPreferenceDraft(draftSessionId, identity, next);
  else saveCapabilityPreferences({ ...identity, scope: 'conversation_connection_model', conversationId }, next);
}

/** The user toggles the web switch; returns false when the identity is absent (cannot be stored). The relay writes the fixed identity. */
export function writeComposerWebPreference(scope: ComposerWebPreferenceScope, next: CapabilityWebPreference): boolean {
  const identity = relayWebPreferenceIdentity(scope.provider, scope.model) ?? capabilityPreferenceIdentity(scope.provider, scope.model);
  if (!identity) return false;
  patchComposerSlot(scope, identity, (previous) => ({ ...previous, web: next }));
  return true;
}

/**
 * The user picks a thinking level (`undefined` = automatic, `'off'` = explicitly off); returns false when the identity is absent.
 * The relay default layer is passed along as well: changing only thinking must not write a web value that was never set (default on) as off.
 */
export function writeComposerReasoningIntent(scope: ComposerWebPreferenceScope, intent: ReasoningIntent | undefined): boolean {
  const identity = capabilityPreferenceIdentity(scope.provider, scope.model);
  if (!identity) return false;
  patchComposerSlot(scope, identity, (previous) => withCapabilityReasoningIntent(previous, intent), relayWebPreferenceDefaultFor(scope.provider, scope.model));
  return true;
}
