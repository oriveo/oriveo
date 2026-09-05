'use client';

import { useDeferredValue, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Check, ChevronDown, ChevronRight, Plus, Search } from 'lucide-react';
import { useTranslations } from 'next-intl';
import type { AIModel, Provider, ProviderKind } from '@oriveo/shared';
import { CAPABILITY_ICONS } from '../../../components/chat/ModelCapabilityBadge';
import { ModelCommercialMetaInline, ModelMetaInline } from '../../../components/chat/ModelMetaInline';
import { MenuSelect, type MenuSelectOption } from '../../../components/MenuSelect';
import { VendorIdentity } from '../../../components/VendorIdentity';
import {
  buildModelBrowserGroups,
  shouldRenderGroupedModelBrowser,
  type ModelBrowserSort,
} from './model-browser-groups';
import styles from './ModelBrowser.module.css';
import { useCapabilityEvidenceCollectionExpiry } from '../../../lib/core/chat/use-capability-evidence-expiry';
import {
  createModelCapabilityPresentationProjector,
  type ModelCapabilityPresentationProjector,
} from '../../../lib/core/chat/model-capability-presentation';

export {
  getVendorBadgePresentation,
  normalizeVendorKey,
  VendorIdentity,
} from '../../../components/VendorIdentity';

const CAP_KEYS = ['image', 'video', 'reasoning', 'file', 'web', 'toolCall'] as const;
const SHORTCUT_LIMIT = 6;
const EXPANDED_GROUP_STORAGE_PREFIX = 'oriveo.modelBrowser.expandedGroup.';

interface ModelBrowserProps {
  catalogModels: AIModel[];
  popularitySourceModels?: AIModel[];
  providerKind: ProviderKind;
  providerLabel: string;
  provider?: Provider;
  onToggleModel: (model: AIModel) => void;
  actionLabel?: (model: AIModel) => string;
  renderActionIcon?: () => ReactNode;
  preserveCatalogOrder?: boolean;
}

interface SearchResultItem {
  groupId: string;
  groupTitle: string;
  model: AIModel;
}

interface ModelRowProps {
  model: AIModel;
  provider?: Provider;
  /** In nested mode the row sits inside a group card: no vendor icon, and a transparent spacer aligns the title with the group header. */
  nested: boolean;
  onAdd: () => void;
  t: (key: string) => string;
  actionLabel?: string;
  renderActionIcon?: () => ReactNode;
  capabilityProjector: ModelCapabilityPresentationProjector;
  /** Only passed in flat / search mode; not shown when nested. */
  groupId?: string;
  groupTitle?: string;
}

export function ModelBrowser({
  catalogModels,
  popularitySourceModels,
  providerKind,
  providerLabel,
  provider,
  onToggleModel,
  actionLabel,
  renderActionIcon,
  preserveCatalogOrder = false,
}: ModelBrowserProps) {
  const t = useTranslations('pages.providerDetail');
  const tc = useTranslations('capability');
  const [query, setQuery] = useState('');
  /**
   * The list recomputes from the deferred query while the input stays bound to the immediate one.
   *
   * Search flattens every matching model into one list (see the data-mode="results" branch
   * below), and a group-name match returns the whole group. Nearly every one of OpenRouter's 355
   * model ids contains "a", so the first keystroke mounts hundreds of rows at roughly 35 DOM
   * nodes each in a single synchronous commit. With a deferred value the keystroke updates the
   * input at high priority while the heavy list catches up in a concurrent render, so that
   * commit stops blocking typing.
   */
  const deferredQuery = useDeferredValue(query);
  const [capFilter, setCapFilter] = useState<string | null>(null);
  const [sortBy, setSortBy] = useState<ModelBrowserSort>('recommended');
  const capabilityEvidenceTargets = useMemo(
    () => provider ? catalogModels.map((model) => ({ provider, model })) : [],
    [catalogModels, provider],
  );
  const capabilityEvidenceTick = useCapabilityEvidenceCollectionExpiry(capabilityEvidenceTargets);
  const capabilityProjector = useMemo(
    () => createModelCapabilityPresentationProjector(),
    [catalogModels, popularitySourceModels, provider, capabilityEvidenceTick],
  );
  // One piece of state instead of the separate selectedGroupId and expandedGroupId: a group is
  // either expanded or collapsed, with no distinction between a pinned scope and a temporary
  // expansion.
  const storageKey = useMemo(() => modelBrowserExpandedGroupStorageKey(providerKind), [providerKind]);
  const [expandedGroupId, setExpandedGroupId] = useState<string | null>(() => readExpandedGroup(storageKey));
  const groupRefs = useRef<Map<string, HTMLElement>>(new Map());

  const groups = useMemo(
    () => buildModelBrowserGroups({
      catalogModels,
      popularitySourceModels,
      query: deferredQuery,
      capFilter,
      sortBy,
      providerKind,
      providerLabel,
      provider,
      capabilityProjector,
      preserveCatalogOrder,
    }),
    [catalogModels, popularitySourceModels, deferredQuery, capFilter, sortBy, providerKind, providerLabel, provider, capabilityProjector, preserveCatalogOrder],
  );

  // Must share a source with groups: deciding the branch on the immediate query while building
  // groups from the deferred one leaves a half-beat where search mode is on but groups are still
  // from the previous round.
  const normalizedQuery = deferredQuery.trim().toLowerCase();
  const shortcutGroups = useMemo(() => groups.slice(0, SHORTCUT_LIMIT), [groups]);
  const shouldGroup = useMemo(
    () => shouldRenderGroupedModelBrowser(providerKind, groups),
    [providerKind, groups],
  );

  const visibleCount = useMemo(
    () => groups.reduce((total, g) => total + g.models.length, 0),
    [groups],
  );

  const sortOptions = useMemo<MenuSelectOption<ModelBrowserSort>[]>(
    () => [
      { value: 'recommended', label: t('sortRecommended'), description: t('sortRecommendedDirection') },
      { value: 'name', label: t('sortName'), description: t('sortNameDirection') },
      { value: 'price', label: t('sortPrice'), description: t('sortPriceDirection') },
      { value: 'context', label: t('sortContext'), description: t('sortContextDirection') },
    ],
    [t],
  );

  // While searching, flatten every group's models into one results list rather than switching to supplier mode on a vendor match
  const searchResults = useMemo<SearchResultItem[]>(
    () => groups.flatMap((g) => g.models.map((m) => ({ groupId: g.id, groupTitle: g.title, model: m }))),
    [groups],
  );

  // Collapse automatically when the expanded group is gone, for example after a capFilter change filtered it out
  useEffect(() => {
    if (expandedGroupId && !groups.some((g) => g.id === expandedGroupId)) {
      setExpandedGroupId(null);
    }
  }, [expandedGroupId, groups]);

  useEffect(() => {
    persistExpandedGroup(storageKey, shouldGroup ? expandedGroupId : null);
  }, [expandedGroupId, shouldGroup, storageKey]);

  // Scroll a newly expanded group into view, so expanding does not leave its content off screen
  useEffect(() => {
    if (!expandedGroupId || normalizedQuery) return;
    const el = groupRefs.current.get(expandedGroupId);
    if (typeof el?.scrollIntoView === 'function') {
      el.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
    }
  }, [expandedGroupId, normalizedQuery]);

  return (
    <div className={styles.browser}>
      <div className={styles.toolbar}>
        <div className={styles.searchShell}>
          <Search className={styles.searchIcon} size={16} />
          <input
            className={styles.searchInput}
            placeholder={t('searchModels')}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            aria-label={t('searchModels')}
          />
        </div>

        <div className={styles.toolbarRow}>
          <div className={styles.filters}>
            {CAP_KEYS.map((cap) => (
              <button
                key={cap}
                type="button"
                className={styles.filterChip}
                data-cap={cap}
                data-active={capFilter === cap}
                onClick={() => setCapFilter(capFilter === cap ? null : cap)}
                aria-pressed={capFilter === cap}
              >
                <span className={styles.filterChipIcon} aria-hidden="true">{CAPABILITY_ICONS[cap]}</span>
                {tc(cap)}
                {capFilter === cap ? (
                  <span className={styles.filterChipCheck} aria-hidden="true">
                    <Check size={12} strokeWidth={2.6} />
                  </span>
                ) : null}
              </button>
            ))}
          </div>
          {/* The sort control is shown for every provider: on aggregators, sorting by price or context is what users need most */}
          <MenuSelect
            className={styles.sortControl}
            value={sortBy}
            options={sortOptions}
            ariaLabel={t('sortBy')}
            minWidth={168}
            menuMinWidth={216}
            showSelectedDescription
            onChange={setSortBy}
          />
        </div>

        <div className={styles.countBar}>
          <span className={styles.count}>{t('catalogCount', { count: visibleCount })}</span>
        </div>
      </div>

      {visibleCount === 0 ? (
        <div className={styles.empty}>{t('noModelsFound')}</div>
      ) : shouldGroup ? (
        normalizedQuery ? (
          // Search mode: a flat results list, with vendor labels as visual anchors
          <div className={styles.list} data-mode="results">
            {searchResults.map(({ groupId, groupTitle, model }) => (
              <ModelRow
                key={`${groupId}::${model.id}`}
                model={model}
                provider={provider}
                nested={false}
                groupId={groupId}
                groupTitle={groupTitle}
                onAdd={() => onToggleModel(model)}
                t={t}
                actionLabel={actionLabel?.(model)}
                renderActionIcon={renderActionIcon}
                capabilityProjector={capabilityProjector}
              />
            ))}
          </div>
        ) : (
          <>
            {/* Vendor shortcut bar: clicking one expands its group directly */}
            {shortcutGroups.length > 0 && (
              <div className={styles.shortcutRail}>
                <button
                  type="button"
                  className={styles.shortcutButton}
                  data-active={expandedGroupId == null}
                  data-all="true"
                  aria-pressed={expandedGroupId == null}
                  onClick={() => setExpandedGroupId(null)}
                >
                  <div className={styles.allShortcutBadge}>{t('allShort')}</div>
                  <span className={styles.shortcutLabel}>{t('allSuppliers')}</span>
                </button>
                {shortcutGroups.map((group) => (
                  <button
                    key={group.id}
                    type="button"
                    data-testid={`shortcut-${group.id}`}
                    className={styles.shortcutButton}
                    data-active={expandedGroupId === group.id}
                    aria-pressed={expandedGroupId === group.id}
                    onClick={() => setExpandedGroupId(expandedGroupId === group.id ? null : group.id)}
                  >
                    <VendorIdentity groupId={group.id} title={group.title} small density="compact" />
                    <span className={styles.shortcutLabel}>{group.title}</span>
                    <span className={styles.shortcutCount}>{group.models.length}</span>
                  </button>
                ))}
              </div>
            )}

            <div className={styles.groupSections}>
              {groups.map((group) => {
                const isExpanded = expandedGroupId === group.id;
                return (
                  <section
                    key={group.id}
                    ref={(node) => {
                      if (node) groupRefs.current.set(group.id, node);
                      else groupRefs.current.delete(group.id);
                    }}
                    className={styles.groupSection}
                    data-testid={`group-${group.id}`}
                    data-expanded={isExpanded}
                  >
                    <button
                      type="button"
                      className={styles.groupButton}
                      aria-expanded={isExpanded}
                      onClick={() => setExpandedGroupId(isExpanded ? null : group.id)}
                    >
                      <VendorIdentity groupId={group.id} title={group.title} density="compact" />
                      <div className={styles.groupCopy}>
                        <span className={styles.groupTitle}>{group.title}</span>
                      </div>
                      <span className={styles.groupCount}>{group.models.length}</span>
                      {isExpanded ? (
                        <ChevronDown className={styles.groupChevron} data-expanded size={16} aria-hidden="true" />
                      ) : (
                        <ChevronRight className={styles.groupChevron} size={16} aria-hidden="true" />
                      )}
                    </button>

                    {isExpanded && (
                      <div className={styles.groupBody}>
                        {group.models.map((model) => (
                          <ModelRow
                            key={model.id}
                            model={model}
                            provider={provider}
                            nested
                            onAdd={() => onToggleModel(model)}
                            t={t}
                            actionLabel={actionLabel?.(model)}
                            renderActionIcon={renderActionIcon}
                            capabilityProjector={capabilityProjector}
                          />
                        ))}
                      </div>
                    )}
                  </section>
                );
              })}
            </div>
          </>
        )
      ) : (
        // A provider without groups gets a flat list, still with sort and capability filter
        <div className={styles.list} data-mode="flat">
          {searchResults.map(({ model }) => (
            <ModelRow
              key={model.id}
              model={model}
              provider={provider}
              nested={false}
              onAdd={() => onToggleModel(model)}
              t={t}
              actionLabel={actionLabel?.(model)}
              renderActionIcon={renderActionIcon}
              capabilityProjector={capabilityProjector}
            />
          ))}
        </div>
      )}
    </div>
  );
}

/**
 * Model row: a compact settings-style row.
 * - nested=true (inside a group card): a 56px transparent spacer replaces the vendor icon so the
 *   name lines up with the group header title
 * - nested=false (search or flat): keeps the vendor label as a visual anchor
 * - the whole row is clickable and adds the model; there is no inline expand for details
 */
function ModelRow({
  model,
  provider,
  nested,
  onAdd,
  t,
  actionLabel,
  renderActionIcon,
  capabilityProjector,
  groupId,
  groupTitle,
}: ModelRowProps) {
  const canAdd = model.isAvailable;
  const label = actionLabel ?? `${t('addModel')}: ${model.name}`;
  return (
    <button
      type="button"
      className={styles.modelRow}
      data-nested={nested}
      data-available={model.isAvailable}
      onClick={canAdd ? onAdd : undefined}
      disabled={!canAdd}
      aria-label={label}
    >
      {nested ? (
        <span className={styles.nestedIndent} aria-hidden="true" />
      ) : groupId && groupTitle ? (
        <VendorIdentity groupId={groupId} title={groupTitle} small density="compact" />
      ) : null}

      <div className={styles.modelContent}>
        <span className={styles.modelName}>{model.name}</span>
        <ModelMetaInline
          model={model}
          provider={provider}
          observeEvidenceExpiry={false}
          capabilityPresentation={provider ? capabilityProjector(provider, model) : undefined}
          containerClassName={styles.modelMeta}
          priceClassName={styles.modelPrice}
        />
        <ModelCommercialMetaInline
          model={model}
          containerClassName={styles.modelSpecs}
          itemClassName={styles.modelSpec}
        />
      </div>

      <div className={styles.modelTrailing}>
        {!canAdd && (
          <span className={styles.unavailableBadge}>{t('unavailable')}</span>
        )}
        <span className={styles.addBubble} aria-hidden="true">
          {renderActionIcon ? renderActionIcon() : <Plus size={14} strokeWidth={2.6} />}
        </span>
      </div>
    </button>
  );
}

function modelBrowserExpandedGroupStorageKey(providerKind: ProviderKind): string {
  return `${EXPANDED_GROUP_STORAGE_PREFIX}${providerKind}`;
}

function readExpandedGroup(storageKey: string): string | null {
  if (typeof window === 'undefined') return null;
  try {
    return window.localStorage.getItem(storageKey);
  } catch {
    return null;
  }
}

function persistExpandedGroup(storageKey: string, groupId: string | null): void {
  if (typeof window === 'undefined') return;
  try {
    if (groupId) {
      window.localStorage.setItem(storageKey, groupId);
    } else {
      window.localStorage.removeItem(storageKey);
    }
  } catch {
    // localStorage can be unavailable in private contexts; grouping still works in memory.
  }
}
