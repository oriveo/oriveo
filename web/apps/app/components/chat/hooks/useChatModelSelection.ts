import { useState, useCallback, useMemo, useEffect, useRef } from 'react';
import { useTranslations } from 'next-intl';
import type { AIModel, Conversation, Provider } from '@oriveo/shared';
import { showToast } from '../../Toast';
import { useAppStore, getVanillaStore } from '../../../providers/StoreProvider';
import { resolveActiveSelection, selectConnectionRemovalJudgeable } from '../../../lib/core/chat/active-selection';
import { consumeModelRetiredHint } from '../../../lib/core/chat/model-retired-hint';
import { resolveRetirementSuccessorModel } from '../../../lib/core/providers/provider-selection-snapshot';
import * as conversationOps from '../../../lib/core/conversation-ops';
import { addManualProviderModels, findModelInProvider } from '../../../lib/core/provider-model-ops';
import { enableProviderModelWithProbe } from '../../../lib/core/relay-model-probe-ops';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../../../lib/core/telemetry';
import { sameNormalizedID } from '../../../lib/utils/id-utils';

interface UseChatModelSelectionParams {
  runtimeProviders: Provider[];
  conversation: Conversation | undefined;
  providers: Provider[];
  evaluateExpensiveHint: (oldModel: AIModel | undefined, newModel: AIModel) => void;
  /** Change signal for the metadata snapshot: recompute the retirement verdict and current model once the catalog has loaded. */
  metadataVersion: number;
}

/**
 * Model selection: resolves the effective provider/model (active-selection) and holds the handlers
 * for manual switching, enabling a model and entering one by hand, plus the model picker open state and its analytics. lastUsedModelRef is read and written here.
 */
export function useChatModelSelection({
  runtimeProviders,
  conversation,
  providers,
  evaluateExpensiveHint,
  metadataVersion,
}: UseChatModelSelectionParams) {
  const t = useTranslations('pages.chat');
  const lastUsedModelRef = useAppStore((s) => s.lastUsedModelRef);
  const setLastUsedModelRef = useAppStore((s) => s.setLastUsedModelRef);
  // A "connection removed" verdict is only possible once the local list has loaded and the connection set has synced (or sync does not apply).
  const connectionsJudgeable = useAppStore(selectConnectionRemovalJudgeable);

  const [showModelSwitcher, setShowModelSwitcher] = useState(false);
  const [selectedModelId, setSelectedModelId] = useState<string | null>(null);
  const [selectedProviderId, setSelectedProviderId] = useState<string | null>(null);

  // ── Resolve active provider and model ──
  const {
    provider, currentModel, modelRemoval, modelRetirement, connectionRemoved, defaultModelHint, unusedPreferredModelId,
  } = useMemo(
    () => resolveActiveSelection(
      runtimeProviders, conversation, selectedProviderId, selectedModelId, lastUsedModelRef, connectionsJudgeable,
    ),
    // metadataVersion is not read inside the callback: it signals that the catalog arrived, and the metadata snapshot the verdict reads changes with it.
    [runtimeProviders, conversation, selectedProviderId, selectedModelId, lastUsedModelRef, connectionsJudgeable, metadataVersion],
  );

  const handleModelSelect = useCallback((model: AIModel, prov: Provider) => {
    // Expensive model switch warning
    evaluateExpensiveHint(currentModel, model);

    const previousProvider = provider;
    const previousModel = currentModel;
    const isActuallyDifferent =
      !previousModel
      || previousModel.id !== model.id
      || !previousProvider
      || previousProvider.id !== prov.id;

    setSelectedModelId(model.id);
    setSelectedProviderId(prov.id);
    setLastUsedModelRef({ providerID: prov.id, modelID: model.id });
    if (conversation) {
      conversationOps.updateConversationModel(getVanillaStore(), conversation.id, model.id, prov.id);
    }

    if (isActuallyDifferent) {
      trackEvent('model_switched', {
        from_model_id: telemetryModelID(previousProvider?.kind, previousModel?.id ?? 'none'),
        to_model_id: telemetryModelID(prov.kind, model.id),
        from_provider_kind: previousProvider?.kind ? telemetryProviderKind(previousProvider.kind) : 'none',
        to_provider_kind: telemetryProviderKind(prov.kind),
        trigger: 'manual',
        in_conversation: Boolean(conversation),
      });
    }
  }, [setLastUsedModelRef, conversation, currentModel, provider, evaluateExpensiveHint]);

  // Session model retired: resolve the successor from the verdict's successorId; neither the verdict nor the name is recomputed here.
  const successorModel = useMemo(
    () => resolveRetirementSuccessorModel(provider, modelRetirement?.successorId),
    [provider, modelRetirement?.successorId],
  );
  const switchToSuccessor = useCallback(() => {
    if (!provider || !successorModel) return;
    handleModelSelect(successorModel, provider);
  }, [handleModelSelect, provider, successorModel]);

  // The preferred model for a new chat was retired and the catalog default is used instead: hint once per device for a given retired model.
  // Dedupe key = last-used connection + original model id, not the connection it fell back to; with no last-used entry, fall back to the preference the verdict reports.
  // A manual pick (the selected connection takes effect) uses its own connection + model and does not borrow the last-used key.
  const fromManualPick = Boolean(selectedProviderId && provider && sameNormalizedID(provider.id, selectedProviderId));
  const hintConnectionId = fromManualPick ? provider?.id : lastUsedModelRef?.providerID ?? provider?.id;
  const hintModelId = fromManualPick
    ? unusedPreferredModelId ?? selectedModelId
    : lastUsedModelRef?.modelID ?? unusedPreferredModelId;
  useEffect(() => {
    if (conversation || !currentModel) return;
    if (!consumeModelRetiredHint(hintConnectionId, hintModelId, defaultModelHint)) return;
    showToast(t('lastUsedModelRetiredHint', { model: currentModel.name }));
  }, [conversation, currentModel, hintConnectionId, hintModelId, defaultModelHint, t]);

  const handleEnableAndSelect = useCallback((model: AIModel, prov: Provider) => {
    // Enabling a single model in the picker is the same action as in the model library: for the Relay form it also lazily verifies the protocol.
    enableProviderModelWithProbe(getVanillaStore(), prov, model);
    handleModelSelect(model, prov);
  }, [handleModelSelect]);

  const handleAddManualAndSelect = useCallback((modelId: string, prov: Provider) => {
    const [newModel] = addManualProviderModels(getVanillaStore(), prov, [modelId]);
    const resolved = newModel ?? findModelInProvider(prov, modelId);
    if (!resolved) return;
    handleModelSelect(resolved, prov);
  }, [handleModelSelect]);

  const handleSwitchModel = useCallback(() => setShowModelSwitcher(true), []);
  const handleToggleModelSwitcher = useCallback(() => setShowModelSwitcher((v) => !v), []);

  // Model picker open analytics, fired once on the closed-to-open edge.
  // The deps include conversation and providers.length because their current values are read when
  // firing, but while the picker **stays open** those change (a background sync replaces the
  // conversation reference, or enabling a model from inside the picker grows providers) and rerun the effect, so a ref guards the edge; otherwise a single open inflates the dashboard with repeats.
  const pickerOpenTrackedRef = useRef(false);
  useEffect(() => {
    if (!showModelSwitcher) {
      pickerOpenTrackedRef.current = false;
      return;
    }
    if (pickerOpenTrackedRef.current) return;
    pickerOpenTrackedRef.current = true;
    trackEvent('model_picker_opened', {
      context: conversation ? 'chat' : 'new_conversation',
      provider_count: providers.length,
    });
  }, [showModelSwitcher, conversation, providers.length]);

  return {
    provider,
    currentModel,
    modelRemoval,
    modelRetirement,
    connectionRemoved,
    successorModel,
    switchToSuccessor,
    setSelectedModelId,
    setSelectedProviderId,
    showModelSwitcher,
    setShowModelSwitcher,
    handleModelSelect,
    handleEnableAndSelect,
    handleAddManualAndSelect,
    handleSwitchModel,
    handleToggleModelSwitcher,
  };
}
