import { ArrowLeft, ChevronDown, Search, X } from "lucide-react";
import { useTranslations } from "next-intl";
import type { Provider } from "@oriveo/shared";
import { VendorIdentity } from "../../VendorIdentity";
import {
  shouldRenderGroupedModelBrowser,
  type ModelBrowserGroup,
} from "../../../app/providers/[providerId]/model-browser-groups";
import { getModelSwitcherProviderLabel } from "../model-switcher-sorting";
import styles from "../ModelSwitcher.module.css";
import { CatalogModelRow } from "./CatalogModelRow";
import { SupplierDirectory } from "./SupplierDirectory";
import type { ModelSwitcherData } from "./hooks/useModelSwitcherData";

interface CatalogViewProps {
  data: ModelSwitcherData;
  activeProvider: Provider;
  onClose: () => void;
}

export function CatalogView({ data, activeProvider, onClose }: CatalogViewProps) {
  const t = useTranslations("pages.modelSwitcher");
  const tc = useTranslations("common");
  const td = useTranslations("pages.providerDetail");

  const {
    catalogSearchRef,
    setView,
    catalogQuery,
    setCatalogQuery,
    selectedCatalogGroupId,
    setSelectedCatalogGroupId,
    expandedCatalogGroupIds,
    toggleCatalogGroup,
    catalogGroups,
    scopedCatalogGroups,
    selectedCatalogGroup,
    catalogShortcutGroups,
    catalogModelCount,
    shouldShowCatalogSupplierDirectory,
    handleCatalogEnableAndSelect,
  } = data;

  const renderGroupedSection = (group: ModelBrowserGroup, withVendorIdentity: boolean) => {
    const isGroupExpanded = expandedCatalogGroupIds.has(group.id);
    return (
      <div key={group.id} className={styles.catalogSection}>
        <button
          type="button"
          className={styles.catalogSectionLabel}
          onClick={() => toggleCatalogGroup(group.id)}
        >
          <div className={styles.catalogSectionLead}>
            <ChevronDown
              size={14}
              className={styles.catalogSectionChevron}
              data-collapsed={!isGroupExpanded || undefined}
            />
            {withVendorIdentity ? (
              <VendorIdentity groupId={group.id} title={group.title} small />
            ) : null}
            <span>{group.title}</span>
          </div>
          <span className={styles.catalogSectionCount}>
            {group.models.length}
          </span>
        </button>
        {isGroupExpanded && (
          <div className={styles.catalogList}>
            {group.models.map((model) => (
              <CatalogModelRow
                key={model.id}
                model={model}
                provider={activeProvider}
                onEnable={handleCatalogEnableAndSelect}
                capabilityProjector={data.capabilityProjector}
              />
            ))}
          </div>
        )}
      </div>
    );
  };

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
            <div className={styles.subHeaderTitleRow}>
              <div className={styles.title}>
                {activeProvider.kind === "relay"
                  ? t("manualEntry")
                  : td("modelCatalog")}
              </div>
              <span className={styles.subHeaderProviderPill}>
                {getModelSwitcherProviderLabel(activeProvider)}
              </span>
              <span className={styles.subHeaderCountBadge}>
                {catalogModelCount}
              </span>
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

      <div className={styles.searchWrap}>
        <Search size={16} className={styles.searchIcon} />
        <input
          ref={catalogSearchRef}
          className={styles.searchInput}
          placeholder={td("searchModels")}
          value={catalogQuery}
          onChange={(event) => setCatalogQuery(event.target.value)}
        />
        {catalogQuery ? (
          <button
            type="button"
            className={styles.clearBtn}
            onClick={() => setCatalogQuery("")}
            aria-label={tc("cancel")}
          >
            <X size={14} />
          </button>
        ) : null}
      </div>

      <div className={styles.list}>
        {catalogModelCount === 0 ? (
          <div className={styles.empty}>
            <div className={styles.emptyTitle}>{td("noModelsFound")}</div>
          </div>
        ) : shouldShowCatalogSupplierDirectory ? (
          <>
            <SupplierDirectory
              catalogQuery={catalogQuery}
              catalogShortcutGroups={catalogShortcutGroups}
              selectedCatalogGroupId={selectedCatalogGroupId}
              setSelectedCatalogGroupId={setSelectedCatalogGroupId}
              selectedCatalogGroup={selectedCatalogGroup}
            />

            {scopedCatalogGroups.map((group) => renderGroupedSection(group, true))}
          </>
        ) : shouldRenderGroupedModelBrowser(
            activeProvider.kind,
            catalogGroups,
          ) ? (
          catalogGroups.map((group) => renderGroupedSection(group, false))
        ) : (
          catalogGroups
            .flatMap((group) => group.models)
            .map((model) => (
              <CatalogModelRow
                key={model.id}
                model={model}
                provider={activeProvider}
                onEnable={handleCatalogEnableAndSelect}
                capabilityProjector={data.capabilityProjector}
              />
            ))
        )}
      </div>
    </>
  );
}
