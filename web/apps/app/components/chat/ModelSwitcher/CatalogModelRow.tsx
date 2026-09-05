import { Plus } from "lucide-react";
import type { AIModel, Provider } from "@oriveo/shared";
import { ModelMetaInline } from "../ModelMetaInline";
import styles from "../ModelSwitcher.module.css";
import type { ModelCapabilityPresentationProjector } from "../../../lib/core/chat/model-capability-presentation";

interface CatalogModelRowProps {
  model: AIModel;
  provider: Provider;
  onEnable: (model: AIModel, provider: Provider) => void;
  capabilityProjector: ModelCapabilityPresentationProjector;
}

export function CatalogModelRow({ model, provider, onEnable, capabilityProjector }: CatalogModelRowProps) {
  return (
    <button
      type="button"
      className={styles.catalogCompactRow}
      onClick={() => onEnable(model, provider)}
    >
      <div className={styles.catalogCompactBody}>
        <div className={styles.catalogCompactMain}>
          <span className={styles.modelName}>{model.name}</span>
        </div>
        <ModelMetaInline
          model={model}
          provider={provider}
          observeEvidenceExpiry={false}
          capabilityPresentation={capabilityProjector(provider, model)}
          containerClassName={styles.catalogMetaRail}
          priceClassName={styles.rowPrice}
          size="xs"
        />
      </div>
      <span className={styles.catalogAddButton}>
        <Plus size={16} className={styles.catalogAddIcon} />
      </span>
    </button>
  );
}
