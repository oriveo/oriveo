import { ArrowLeft, X } from "lucide-react";
import { useTranslations } from "next-intl";
import type { Provider } from "@oriveo/shared";
import { ProviderIcon } from "../../ProviderIcon";
import { getModelSwitcherProviderLabel } from "../model-switcher-sorting";
import styles from "../ModelSwitcher.module.css";
import type { ModelSwitcherData } from "./hooks/useModelSwitcherData";

interface ManualEntryViewProps {
  data: ModelSwitcherData;
  activeProvider: Provider;
  onClose: () => void;
}

export function ManualEntryView({ data, activeProvider, onClose }: ManualEntryViewProps) {
  const t = useTranslations("pages.modelSwitcher");
  const tc = useTranslations("common");
  const tm = useTranslations("pages.manualModel");

  const {
    manualInputRef,
    setView,
    manualModelId,
    setManualModelId,
    existingManualModel,
    handleManualSubmit,
  } = data;

  return (
    <>
      <div className={styles.subHeader}>
        <div className={styles.subHeaderPrimary}>
          <button
            type="button"
            className={styles.backBtn}
            onClick={() => setView({ kind: "browse" })}
            aria-label={tc("back")}
          >
            <ArrowLeft size={16} />
          </button>
          <div className={styles.subHeaderText}>
            <div className={styles.title}>{t("manualEntry")}</div>
            <div className={styles.subtitle}>
              {getModelSwitcherProviderLabel(activeProvider)}
            </div>
          </div>
        </div>
        <button
          type="button"
          className={styles.closeBtn}
          onClick={onClose}
          aria-label={tc("cancel")}
        >
          <X size={16} />
        </button>
      </div>

      <div className={styles.manualBody}>
        <div className={styles.manualHero}>
          <div className={styles.manualProvider}>
            <span className={styles.providerMark}>
              <ProviderIcon kind={activeProvider.kind} size={18} bare />
            </span>
            <span>{getModelSwitcherProviderLabel(activeProvider)}</span>
          </div>
          <div className={styles.manualHint}>
            {tm("description", {
              provider: getModelSwitcherProviderLabel(activeProvider),
            })}
          </div>
        </div>

        <div className={styles.manualField}>
          <label className={styles.manualLabel} htmlFor="manual-model-id">
            {tm("modelIdLabel")}
          </label>
          <div className={styles.manualInputWrap}>
            <input
              id="manual-model-id"
              ref={manualInputRef}
              className={styles.manualInput}
              placeholder={tm("modelIdPlaceholder")}
              value={manualModelId}
              onChange={(event) => setManualModelId(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  handleManualSubmit();
                }
              }}
            />
          </div>
        </div>

        {existingManualModel ? (
          <div className={styles.manualExisting}>
            {t("existingModelHint", { model: existingManualModel.name })}
          </div>
        ) : null}

        <button
          type="button"
          className={styles.primaryAction}
          disabled={!manualModelId.trim()}
          onClick={handleManualSubmit}
        >
          {existingManualModel
            ? t("switchToExisting")
            : t("addAndSwitch")}
        </button>
      </div>
    </>
  );
}
