import { useState } from "react";
import { ChevronDown, Plus } from "lucide-react";
import { useTranslations } from "next-intl";
import type { AIModel, Provider } from "@oriveo/shared";
import { sameNormalizedID } from "../../../lib/utils/id-utils";
import { ProviderIcon } from "../../ProviderIcon";
import { VendorIdentity } from "../../VendorIdentity";
import styles from "../ModelSwitcher.module.css";
import { ModelRowItem } from "./ModelRowItem";
import { groupModelsByVendor } from "./model-vendor-groups";
import type { ProviderSection } from "./presentation-mode";
import type { ModelCapabilityPresentationProjector } from "../../../lib/core/chat/model-capability-presentation";

interface ProviderSectionRowProps {
  section: ProviderSection;
  selectedProviderId: string | undefined;
  selectedModelId: string | undefined;
  normalizedQuery: string;
  hasFilters: boolean;
  expandedProviderIds: Set<string>;
  setExpandedProviderIds: React.Dispatch<React.SetStateAction<Set<string>>>;
  openAddView: (provider: Provider) => void;
  onSelect: (model: AIModel, provider: Provider) => void;
  capabilityProjector: ModelCapabilityPresentationProjector;
}

export function ProviderSectionRow({
  section,
  selectedProviderId,
  selectedModelId,
  normalizedQuery,
  hasFilters,
  expandedProviderIds,
  setExpandedProviderIds,
  openAddView,
  onSelect,
  capabilityProjector,
}: ProviderSectionRowProps) {
  const tp = useTranslations("pages.providerList");
  const td = useTranslations("pages.providerDetail");

  const isExpanded =
    normalizedQuery || hasFilters
      ? true
      : expandedProviderIds.has(section.provider.id);
  const providerBadgeCount =
    normalizedQuery || hasFilters
      ? section.models.length
      : section.provider.models.length;
  const sectionIsActive = sameNormalizedID(
    section.provider.id,
    selectedProviderId,
  );

  // Vendor subgroups start collapsed, showing only the vendor row until the user expands one.
  // The only group expanded by default is the one holding the model this conversation is using,
  // so the model in use is never hidden behind a collapsed group.
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(() => {
    if (!sectionIsActive || !selectedModelId) return new Set();
    const active = section.models.find((model) => model.id === selectedModelId);
    return active?.groupKey ? new Set([active.groupKey]) : new Set();
  });
  const vendorGroups = groupModelsByVendor(section.models);
  const isGrouped = vendorGroups.length > 1;

  return (
    <section
      key={section.provider.id}
      className={styles.providerSection}
      data-active={sectionIsActive}
      data-expanded={isExpanded}
    >
      <div className={styles.providerHeader}>
        <button
          type="button"
          className={styles.providerToggle}
          onClick={() => {
            if (normalizedQuery || hasFilters) return;
            setExpandedProviderIds((prev) => {
              if (prev.has(section.provider.id)) {
                return new Set<string>();
              }
              return new Set([section.provider.id]);
            });
          }}
          aria-expanded={isExpanded}
        >
          <span
            className={styles.providerChevron}
            data-collapsed={!isExpanded || undefined}
            aria-hidden="true"
          >
            <ChevronDown size={14} />
          </span>
          <span className={styles.providerMark}>
            <ProviderIcon
              kind={section.provider.kind}
              size={22}
              bare
            />
          </span>
          <span className={styles.providerName}>{section.providerName}</span>
          <span className={styles.providerCount}>
            {tp("modelCount", {
              count: section.provider.models.length,
            })}
          </span>
        </button>
        <div className={styles.providerHeaderActions}>
          <span className={styles.providerBadge}>{providerBadgeCount}</span>
          {section.canAddModels ? (
            <button
              type="button"
              className={styles.providerAddButton}
              onClick={() => openAddView(section.provider)}
              aria-label={td("addModel")}
            >
              <Plus size={14} />
              <span>{td("addModel")}</span>
            </button>
          ) : null}
        </div>
      </div>

      {isExpanded ? (
        <div className={styles.providerBody}>
          {section.models.length === 0 ? (
            <div className={styles.sectionEmpty}>
              {td("noEnabledModels")}
            </div>
          ) : isGrouped ? (
            vendorGroups.map((group) => {
              // Force expansion while searching or filtering so matches are not hidden by a collapsed group (symmetric with isExpanded at the provider level)
              const collapsed =
                normalizedQuery || hasFilters
                  ? false
                  : !expandedGroups.has(group.key);
              return (
                <div key={group.key} className={styles.catalogSection}>
                  <button
                    type="button"
                    className={styles.catalogSectionLabel}
                    onClick={() =>
                      setExpandedGroups((prev) => {
                        const next = new Set(prev);
                        if (next.has(group.key)) next.delete(group.key);
                        else next.add(group.key);
                        return next;
                      })
                    }
                    aria-expanded={!collapsed}
                  >
                    <span className={styles.catalogSectionLead}>
                      <ChevronDown
                        size={14}
                        className={styles.catalogSectionChevron}
                        data-collapsed={collapsed || undefined}
                      />
                      <VendorIdentity
                        groupId={group.key}
                        title={group.name}
                        small
                      />
                      <span>{group.name}</span>
                    </span>
                    <span className={styles.catalogSectionCount}>
                      {group.models.length}
                    </span>
                  </button>
                  {!collapsed ? (
                    <div className={styles.catalogList}>
                      {group.models.map((model) => {
                        const isSelected =
                          sectionIsActive && model.id === selectedModelId;
                        const isDisabled =
                          model.isAvailable === false && !isSelected;
                        return (
                          <ModelRowItem
                            key={`${section.provider.id}-${model.id}`}
                            model={model}
                            provider={section.provider}
                            isSelected={isSelected}
                            isDisabled={isDisabled}
                            onSelect={onSelect}
                            capabilityProjector={capabilityProjector}
                          />
                        );
                      })}
                    </div>
                  ) : null}
                </div>
              );
            })
          ) : (
            section.models.map((model) => {
              const isSelected =
                sectionIsActive && model.id === selectedModelId;
              const isDisabled =
                model.isAvailable === false && !isSelected;
              return (
                <ModelRowItem
                  key={`${section.provider.id}-${model.id}`}
                  model={model}
                  provider={section.provider}
                  isSelected={isSelected}
                  isDisabled={isDisabled}
                  onSelect={onSelect}
                  capabilityProjector={capabilityProjector}
                />
              );
            })
          )}
        </div>
      ) : null}
    </section>
  );
}
