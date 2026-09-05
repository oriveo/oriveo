import { useState, useCallback, useMemo, useEffect, useRef } from 'react';
import type { AIModel, Conversation, Provider } from '@oriveo/shared';
import { useAppStore, getVanillaStore } from '../../../providers/StoreProvider';
import { resolveActiveSelection } from '../../../lib/core/chat/active-selection';
import * as conversationOps from '../../../lib/core/conversation-ops';
import { addManualProviderModels, enableProviderModel, findModelInProvider } from '../../../lib/core/provider-model-ops';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../../../lib/core/telemetry';

interface UseChatModelSelectionParams {
  runtimeProviders: Provider[];
  conversation: Conversation | undefined;
  providers: Provider[];
  evaluateExpensiveHint: (oldModel: AIModel | undefined, newModel: AIModel) => void;
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
}: UseChatModelSelectionParams) {
  const lastUsedModelRef = useAppStore((s) => s.lastUsedModelRef);
  const setLastUsedModelRef = useAppStore((s) => s.setLastUsedModelRef);

  const [showModelSwitcher, setShowModelSwitcher] = useState(false);
  const [selectedModelId, setSelectedModelId] = useState<string | null>(null);
  const [selectedProviderId, setSelectedProviderId] = useState<string | null>(null);

  // ── Resolve active provider and model ──
  const { provider, currentModel } = useMemo(
    () => resolveActiveSelection(runtimeProviders, conversation, selectedProviderId, selectedModelId, lastUsedModelRef),
    [runtimeProviders, conversation, selectedProviderId, selectedModelId, lastUsedModelRef],
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

  const handleEnableAndSelect = useCallback((model: AIModel, prov: Provider) => {
    enableProviderModel(getVanillaStore(), prov, model);
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
