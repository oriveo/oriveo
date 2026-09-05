import type { AIModel, Conversation, Provider } from '@oriveo/shared';
import { providerControlsAreManaged } from './stream-options';
import { generationParameterProfileFingerprint, migrateGenerationParameterSession } from './generation-parameter-settings';
import { capabilityRuntimeIdentity, migrateCapabilityPreferenceDraft } from './capability-preference-settings';

/**
 * Moves the model-control scopes from a draft conversation to the real one, both kinds in one pass.
 *
 * A new conversation only gets an id the moment its first message goes out; until then everything
 * the user changed in the panels lives under a local draft id. So creating the conversation has to
 * move both tables at once:
 * - Generation parameters (the scope records in `generation-parameter-settings`)
 * - Typed capability preference drafts (the draft slots in `capability-preference-settings`)
 *
 * Both moves live in one function so that callers cannot drift apart. Moving only the generation
 * parameters - easy to do on a path such as `operations-library-send`, where the first message
 * already runs a library retrieval - silently loses the web and reasoning preferences set while
 * drafting, and a missing copy gives no compile-time signal at all. Any new send path that creates
 * a conversation should call this one function rather than copying
 * `migrateGenerationParameterSession`.
 */
export function migrateDraftScopedModelControls(input: {
  provider: Provider;
  model: AIModel;
  /** An existing conversation is not a new one, so nothing moves. */
  conversation: Conversation | undefined;
  draftSessionId: string | undefined;
  conversationId: string;
}): void {
  const { provider, model, conversation, draftSessionId, conversationId } = input;
  // The request shape of a managed connection is owned entirely by the server, so there is no local model-control state to move.
  if (providerControlsAreManaged(provider) || conversation || !draftSessionId) return;
  migrateGenerationParameterSession({
    providerId: provider.id,
    modelId: model.id,
    fromConversationId: draftSessionId,
    toConversationId: conversationId,
    profileFingerprint: generationParameterProfileFingerprint(provider, model),
  });
  const identity = capabilityRuntimeIdentity(provider, model);
  if (identity) migrateCapabilityPreferenceDraft(draftSessionId, { ...identity, conversationId });
}
