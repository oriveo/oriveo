"use client";

import { useMemo } from "react";
import { useTranslations } from "next-intl";
import type { AIModel, Provider } from "@oriveo/shared";
import styles from "./ModelSwitcher.module.css";
import { BrowseView } from "./ModelSwitcher/BrowseView";
import { CatalogView } from "./ModelSwitcher/CatalogView";
import { ManualEntryView } from "./ModelSwitcher/ManualEntryView";
import { useArrowKeyboardNavigation } from "./ModelSwitcher/hooks/useArrowKeyboardNavigation";
import { useModelSwitcherData } from "./ModelSwitcher/hooks/useModelSwitcherData";
import { useCapabilityEvidenceCollectionExpiry } from "../../lib/core/chat/use-capability-evidence-expiry";

interface ModelSwitcherProps {
  providers: Provider[];
  selectedProviderId?: string;
  selectedModelId?: string;
  currentModel?: AIModel;
  /**
   * The user is on the a user-owned provider free tier (decided by the balance and weekly quota status the server sends).
   * When true, managed models with `free_quota_eligible=false` get a paid badge; selectability is unaffected.
   */
  onSelect: (model: AIModel, provider: Provider) => void;
  onEnableAndSelect: (model: AIModel, provider: Provider) => void;
  onAddManualAndSelect: (modelId: string, provider: Provider) => void;
  onClose: () => void;
  /**
   * Primary action: arriving from "see models supporting this parameter" on a not-adjustable row lists only
   * models this generation parameter can actually drive, reusing the existing test rather than adding a second one.
   */
  requiredGenerationParameterId?: string;
}

export function ModelSwitcher({
  providers,
  selectedProviderId,
  selectedModelId,
  currentModel,
  onSelect,
  onEnableAndSelect,
  onAddManualAndSelect,
  onClose,
  requiredGenerationParameterId,
}: ModelSwitcherProps) {
  const t = useTranslations("pages.modelSwitcher");
  const evidenceTargets = useMemo(() => capabilityEvidenceTargets(providers), [providers]);
  const capabilityEvidenceTick = useCapabilityEvidenceCollectionExpiry(evidenceTargets);

  const data = useModelSwitcherData({
    providers,
    selectedProviderId,
    selectedModelId,
    currentModel,
    onSelect,
    onEnableAndSelect,
    onAddManualAndSelect,
    capabilityEvidenceTick,
    requiredGenerationParameterId,
  });

  const handleKeyDown = useArrowKeyboardNavigation({
    view: data.view,
    listRef: data.listRef,
    onClose,
    setView: data.setView,
  });

  return (
    <>
      <div className={styles.overlay} onClick={onClose} />
      <div
        className={styles.dropdown}
        data-view={data.view.kind}
        onKeyDown={handleKeyDown}
        role="dialog"
        aria-modal="true"
        aria-label={t("selectModel")}
      >
        <div className={styles.mobileHandle} />

        {data.view.kind === "browse" ? (
          <BrowseView
            data={data}
            selectedProviderId={selectedProviderId}
            selectedModelId={selectedModelId}
            onClose={onClose}
          />
        ) : data.view.kind === "catalog" && data.activeProvider ? (
          <CatalogView
            data={data}
            activeProvider={data.activeProvider}
            onClose={onClose}
          />
        ) : data.activeProvider ? (
          <ManualEntryView
            data={data}
            activeProvider={data.activeProvider}
            onClose={onClose}
          />
        ) : null}
      </div>
    </>
  );
}

function capabilityEvidenceTargets(providers: Provider[]) {
  return providers.flatMap((provider) => {
    const uniqueModels = new Map(
      [...provider.models, ...provider.catalogModels].map((model) => [model.id, model]),
    );
    return [...uniqueModels.values()].map((model) => ({ provider, model }));
  });
}
