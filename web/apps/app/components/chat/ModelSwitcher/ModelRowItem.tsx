import { Check } from "lucide-react";
import { useTranslations } from "next-intl";
import type { AIModel, Provider } from "@oriveo/shared";
import { ModelCapabilityBadges } from "../ModelCapabilityBadge";
import { useModelPriceTierLabel } from "../model-price-tier-label";
import styles from "../ModelSwitcher.module.css";
import {
  cleanModelName,
  extractVendorFromName,
  formatContextLength,
  isFreeModel,
} from "./model-switcher-data";
import { visibleModelCapabilityBadges } from "../../../lib/core/chat/model-capability-presentation";
import type { ModelCapabilityPresentationProjector } from "../../../lib/core/chat/model-capability-presentation";

interface ModelRowItemProps {
  model: AIModel;
  provider: Provider;
  isSelected: boolean;
  isDisabled: boolean;
  /** The user is on the managed free tier (no paid balance, running on the weekly allowance); the caller decides this from the balance status the backend reports. */
  onSelect: (model: AIModel, provider: Provider) => void;
  capabilityProjector: ModelCapabilityPresentationProjector;
}

export function ModelRowItem({
  model,
  provider,
  isSelected,
  isDisabled,
  onSelect,
  capabilityProjector,
}: ModelRowItemProps) {
  const t = useTranslations("pages.modelSwitcher");
  const cleanedName = cleanModelName(model.name);
  const vendorPrefix = extractVendorFromName(model.name);
  const ctxLabel = formatContextLength(model.contextLength);
  const priceTierLabel = useModelPriceTierLabel(model.priceTier);
  const showPriceTier = Boolean(priceTierLabel) && !isFreeModel(model);
  const visibleCapabilities = visibleModelCapabilityBadges(
    provider,
    model,
    capabilityProjector(provider, model),
  );
  return (
    <button
      type="button"
      className={styles.modelRow}
      data-selected={isSelected}
      data-disabled={isDisabled}
      data-recommended={model.isRecommended || undefined}
      data-model-row="true"
      disabled={isDisabled}
      onClick={() => onSelect(model, provider)}
    >
      <span className={styles.modelRowAccent} aria-hidden="true" />
      <div className={styles.modelRowBody}>
        <div className={styles.modelTitleBlock}>
          <span className={styles.modelName}>{cleanedName}</span>
        </div>
        <div className={styles.modelMetaRow}>
          {vendorPrefix ? (
            <span className={styles.metaVendor}>{vendorPrefix}</span>
          ) : null}
          {ctxLabel ? (
            <>
              {vendorPrefix ? (
                <span className={styles.metaSep} aria-hidden="true">
                  -
                </span>
              ) : null}
              <span className={styles.metaContext}>{ctxLabel}</span>
            </>
          ) : null}
          {visibleCapabilities.length > 0 ? (
            <span className={styles.metaCaps}>
              <ModelCapabilityBadges
                capabilities={visibleCapabilities}
                size="xs"
                badgeOrder={model.badgeOrder}
              />
            </span>
          ) : null}
          {showPriceTier ? (
            <span className={styles.rowPrice}>{priceTierLabel}</span>
          ) : null}
          {isFreeModel(model) ? (
            <span className={styles.freeTag}>{t("filterFree")}</span>
          ) : null}
          {model.executionLocality === "proxied_cloud" ? (
            <span className={styles.paidTag}>{t("viaOllamaCloud")}</span>
          ) : model.localLoadState === "loading" ? (
            <span className={styles.metaContext}>{t("localModelLoading")}</span>
          ) : model.localLoadState === "unloaded" ? (
            <span className={styles.metaContext}>{t("localModelUnloaded")}</span>
          ) : model.localLoadState === "unknown" ? (
            <span className={styles.metaContext}>{t("localModelStateUnknown")}</span>
          ) : null}
        </div>
      </div>
      <span className={styles.modelRowAction} aria-hidden="true">
        {isSelected ? (
          <span className={styles.modelSelectedBadge}>
            <Check size={12} className={styles.modelSelectedIcon} />
          </span>
        ) : null}
      </span>
    </button>
  );
}
