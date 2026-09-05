import { Sparkles } from "lucide-react";
import { useTranslations } from "next-intl";
import { ModelCapabilityBadges } from "../ModelCapabilityBadge";
import styles from "../ModelSwitcher.module.css";
import { CAPABILITY_FILTERS, type FilterKey } from "./presentation-mode";

interface FilterChipsProps {
  activeFilters: Set<FilterKey>;
  hasFilters: boolean;
  toggleFilter: (key: FilterKey) => void;
  clearFilters: () => void;
  /** Real match count per capability filter. Derived from the same rule as the row badges; the chip only displays it. */
  capabilityFilterCounts: Readonly<Record<FilterKey, number>>;
}

export function FilterChips({
  activeFilters,
  hasFilters,
  toggleFilter,
  clearFilters,
  capabilityFilterCounts,
}: FilterChipsProps) {
  const t = useTranslations("pages.modelSwitcher");
  const tcap = useTranslations("capability");

  return (
    <div
      className={styles.filterChips}
      role="toolbar"
      aria-label={t("filterToolbarAria")}
    >
      <button
        type="button"
        className={styles.filterChip}
        data-active={!hasFilters}
        onClick={clearFilters}
      >
        {t("filterAll")}
      </button>
      <button
        type="button"
        className={styles.filterChip}
        data-active={activeFilters.has("recommended")}
        onClick={() => toggleFilter("recommended")}
      >
        <Sparkles size={12} aria-hidden="true" />
        {t("filterRecommended")}
      </button>
      <button
        type="button"
        className={styles.filterChip}
        data-active={activeFilters.has("free")}
        onClick={() => toggleFilter("free")}
      >
        {t("filterFree")}
      </button>
      <span className={styles.filterDivider} aria-hidden="true" />
      {CAPABILITY_FILTERS.map((entry) => {
        const count = capabilityFilterCounts[entry.key] ?? 0;
        return (
          <button
            key={entry.key}
            type="button"
            className={styles.filterChip}
            data-active={activeFilters.has(entry.key)}
            data-count={count}
            data-empty={count === 0 || undefined}
            onClick={() => toggleFilter(entry.key)}
            aria-label={tcap(entry.capability)}
          >
            <ModelCapabilityBadges
              capabilities={[entry.capability]}
              size="xs"
              iconOnly
            />
            <span className={styles.filterChipLabel}>
              {tcap(entry.capability)}
            </span>
            {/* A 0 is shown as-is: hiding it would let the user click through only to find the list empty */}
            <span className={styles.filterChipCount}>{count}</span>
          </button>
        );
      })}
    </div>
  );
}
