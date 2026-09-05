import { Plus, Search, X } from "lucide-react";
import { useTranslations } from "next-intl";
import { getModelSwitcherProviderLabel } from "../model-switcher-sorting";
import styles from "../ModelSwitcher.module.css";
import { FilterChips } from "./FilterChips";
import { ProviderSectionRow } from "./ProviderSectionRow";
import type { ModelSwitcherData } from "./hooks/useModelSwitcherData";

interface BrowseViewProps {
  data: ModelSwitcherData;
  selectedProviderId: string | undefined;
  selectedModelId: string | undefined;
  onClose: () => void;
}

export function BrowseView({
  data,
  selectedProviderId,
  selectedModelId,
  onClose,
}: BrowseViewProps) {
  const t = useTranslations("pages.modelSwitcher");
  const tc = useTranslations("common");

  const {
    browseSearchRef,
    listRef,
    query,
    setQuery,
    activeFilters,
    toggleFilter,
    clearFilters,
    hasFilters,
    normalizedQuery,
    expandedProviderIds,
    setExpandedProviderIds,
    providerSections,
    addableProviders,
    openAddView,
    onSelect,
  } = data;

  return (
    <>
      <div className={styles.header}>
        <div className={styles.headerMain}>
          <div className={styles.headerText}>
            <div className={styles.title}>{t("selectModel")}</div>
            <div className={styles.subtitle}>{t("browseHint")}</div>
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
      </div>

      <div className={styles.browseChrome}>
        <div className={styles.searchWrap}>
          <Search size={16} className={styles.searchIcon} />
          <input
            ref={browseSearchRef}
            className={styles.searchInput}
            placeholder={t("searchPlaceholder")}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
          />
          {query ? (
            <button
              type="button"
              className={styles.clearBtn}
              onClick={() => setQuery("")}
              aria-label={tc("cancel")}
            >
              <X size={14} />
            </button>
          ) : null}
        </div>

        <FilterChips
          activeFilters={activeFilters}
          hasFilters={hasFilters}
          toggleFilter={toggleFilter}
          clearFilters={clearFilters}
          capabilityFilterCounts={data.capabilityFilterCounts}
        />
      </div>

      <div className={styles.list} ref={listRef}>
        {providerSections.length === 0 ? (
          <div className={styles.empty}>
            <div className={styles.emptyTitle}>{t("noResults")}</div>
            {addableProviders.length > 0 ? (
              <div className={styles.emptyActionList}>
                {addableProviders.map((provider) => (
                  <button
                    key={provider.id}
                    type="button"
                    className={styles.emptyProviderAction}
                    onClick={() => openAddView(provider)}
                  >
                    <div className={styles.emptyProviderInfo}>
                      <span className={styles.emptyProviderName}>
                        {getModelSwitcherProviderLabel(provider)}
                      </span>
                      <span className={styles.emptyProviderHint}>
                        {provider.kind === "relay"
                          ? t("manualEntry")
                          : t("browseCatalog")}
                      </span>
                    </div>
                    <Plus size={14} />
                  </button>
                ))}
              </div>
            ) : null}
          </div>
        ) : (
          providerSections.map((section) => (
            <ProviderSectionRow
              key={section.provider.id}
              section={section}
              selectedProviderId={selectedProviderId}
              selectedModelId={selectedModelId}
              normalizedQuery={normalizedQuery}
              hasFilters={hasFilters}
              expandedProviderIds={expandedProviderIds}
              setExpandedProviderIds={setExpandedProviderIds}
              openAddView={openAddView}
              onSelect={onSelect}
              capabilityProjector={data.capabilityProjector}
            />
          ))
        )}
      </div>
    </>
  );
}
