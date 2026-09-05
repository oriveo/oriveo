import { useEffect, useMemo, useRef, useState } from "react";
import type { AIModel, Provider } from "@oriveo/shared";
import { findModelInProvider } from "../../../../lib/core/provider-model-ops";
import { selectResolvedCatalog } from "../../../../lib/core/store/selectors";
import { onVersionChange } from "../../../../lib/core/metadata/metadata-client";
import { sameNormalizedID } from "../../../../lib/utils/id-utils";
import {
  buildModelBrowserGroups,
  type ModelBrowserGroup,
} from "../../../../app/providers/[providerId]/model-browser-groups";
import {
  getDefaultExpandedModelSwitcherProviderIds,
  getModelSwitcherProviderLabel,
  sortModelSwitcherProviders,
} from "../../model-switcher-sorting";
import {
  CAPABILITY_FILTERS,
  CATALOG_SHORTCUT_LIMIT,
  type FilterKey,
  type ProviderSection,
  type SwitcherView,
} from "../presentation-mode";
import {
  modelMatchesFilters,
  modelMatchesQuery,
  sortProviderModels,
  supportsAddModels,
} from "../model-switcher-data";
import {
  createModelCapabilityPresentationProjector,
  type ModelCapabilityPresentationProjector,
} from "../../../../lib/core/chat/model-capability-presentation";

interface UseModelSwitcherDataParams {
  providers: Provider[];
  selectedProviderId?: string;
  selectedModelId?: string;
  currentModel?: AIModel;
  onSelect: (model: AIModel, provider: Provider) => void;
  onEnableAndSelect: (model: AIModel, provider: Provider) => void;
  onAddManualAndSelect: (modelId: string, provider: Provider) => void;
  capabilityEvidenceTick?: number;
  /** Primary action: list only the models this generation parameter can actually drive (same test used for the chip counts). */
  requiredGenerationParameterId?: string;
}

export interface ModelSwitcherData {
  // refs
  browseSearchRef: React.RefObject<HTMLInputElement | null>;
  catalogSearchRef: React.RefObject<HTMLInputElement | null>;
  manualInputRef: React.RefObject<HTMLInputElement | null>;
  listRef: React.RefObject<HTMLDivElement | null>;

  // view state
  view: SwitcherView;
  setView: (next: SwitcherView) => void;

  // browse state
  query: string;
  setQuery: (q: string) => void;
  activeFilters: Set<FilterKey>;
  toggleFilter: (key: FilterKey) => void;
  clearFilters: () => void;
  hasFilters: boolean;
  normalizedQuery: string;
  expandedProviderIds: Set<string>;
  setExpandedProviderIds: React.Dispatch<React.SetStateAction<Set<string>>>;

  // browse derived
  providerSections: ProviderSection[];
  addableProviders: Provider[];
  /**
   * The **real** hit count behind each capability filter chip.
   *
   * Counted as: enabled models of the currently visible providers, intersected with the current search
   * term, evaluated per capability. Already-selected filters are deliberately **not** applied: the number
   * on a chip answers "how many are left if I click it", and folding itself in would always equal the
   * current list length. The test is borrowed from `modelMatchesFilters` (-> `capabilityAvailableForDisplay`).
   */
  capabilityFilterCounts: Readonly<Record<FilterKey, number>>;
  capabilityProjector: ModelCapabilityPresentationProjector;

  // catalog state
  catalogQuery: string;
  setCatalogQuery: (q: string) => void;
  selectedCatalogGroupId: string | null;
  setSelectedCatalogGroupId: (id: string | null) => void;
  expandedCatalogGroupIds: Set<string>;
  toggleCatalogGroup: (groupId: string) => void;

  // catalog derived
  activeProvider: Provider | null;
  catalogGroups: ModelBrowserGroup[];
  catalogAllGroups: ModelBrowserGroup[];
  scopedCatalogGroups: ModelBrowserGroup[];
  selectedCatalogGroup: ModelBrowserGroup | null;
  catalogShortcutGroups: ModelBrowserGroup[];
  catalogModelCount: number;
  shouldShowCatalogSupplierDirectory: boolean;

  // manual state
  manualModelId: string;
  setManualModelId: (id: string) => void;
  existingManualModel: AIModel | undefined;

  // actions
  openAddView: (provider: Provider) => void;
  returnToBrowse: () => void;
  handleCatalogEnableAndSelect: (model: AIModel, provider: Provider) => void;
  handleManualSubmit: () => void;
  onSelect: (model: AIModel, provider: Provider) => void;
}

const EXPANDED_CATALOG_GROUPS_KEY = "oriveo.modelSwitcher.expandedCatalogGroups.v1";

function readExpandedCatalogGroups(): Set<string> {
  if (typeof window === "undefined") return new Set();
  try {
    const raw = window.localStorage.getItem(EXPANDED_CATALOG_GROUPS_KEY);
    if (!raw) return new Set();
    const parsed = JSON.parse(raw) as unknown;
    return Array.isArray(parsed)
      ? new Set(parsed.filter((id): id is string => typeof id === "string"))
      : new Set();
  } catch {
    return new Set();
  }
}

function writeExpandedCatalogGroups(ids: Set<string>): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(EXPANDED_CATALOG_GROUPS_KEY, JSON.stringify([...ids]));
  } catch {
    /* quota / disabled: ignored, remembering the collapsed state is not critical */
  }
}

export function useModelSwitcherData({
  providers,
  selectedProviderId,
  selectedModelId,
  currentModel,
  onSelect,
  onEnableAndSelect,
  onAddManualAndSelect,
  capabilityEvidenceTick = 0,
  requiredGenerationParameterId,
}: UseModelSwitcherDataParams): ModelSwitcherData {
  const [view, setView] = useState<SwitcherView>({ kind: "browse" });
  const [query, setQuery] = useState("");
  const [activeFilters, setActiveFilters] = useState<Set<FilterKey>>(new Set());
  const [catalogQuery, setCatalogQuery] = useState("");
  const [selectedCatalogGroupId, setSelectedCatalogGroupId] = useState<
    string | null
  >(null);
  const [manualModelId, setManualModelId] = useState("");
  const [expandedProviderIds, setExpandedProviderIds] = useState<Set<string>>(new Set());
  const [expandedCatalogGroupIds, setExpandedCatalogGroupIds] = useState<
    Set<string>
  >(new Set());
  // Collapsed state is remembered locally (managed model groups included); loading it in an effect avoids an SSR hydration mismatch.
  useEffect(() => {
    const stored = readExpandedCatalogGroups();
    if (stored.size > 0) setExpandedCatalogGroupIds(stored);
  }, []);
  // A change of catalog version triggers a recompute of the resolved catalog
  const [metadataTick, setMetadataTick] = useState(0);
  useEffect(() => {
    const unsubscribe = onVersionChange(() => setMetadataTick((t) => t + 1));
    return unsubscribe;
  }, []);

  const capabilityProjector = useMemo(
    () => createModelCapabilityPresentationProjector(),
    [providers, capabilityEvidenceTick, metadataTick],
  );

  const browseSearchRef = useRef<HTMLInputElement>(null);
  const catalogSearchRef = useRef<HTMLInputElement>(null);
  const manualInputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  const toggleCatalogGroup = (groupId: string) => {
    setExpandedCatalogGroupIds((prev) => {
      const next = new Set(prev);
      if (next.has(groupId)) {
        next.delete(groupId);
      } else {
        next.add(groupId);
      }
      writeExpandedCatalogGroups(next);
      return next;
    });
  };

  useEffect(() => {
    const focusTarget =
      view.kind === "browse"
        ? browseSearchRef.current
        : view.kind === "catalog"
          ? catalogSearchRef.current
          : manualInputRef.current;

    focusTarget?.focus();
  }, [view]);

  const visibleProviders = useMemo(() => {
    const available = providers.filter(
      (provider) =>
        provider.status.kind === "connected" ||
        sameNormalizedID(provider.id, selectedProviderId),
    );

    return sortModelSwitcherProviders(available, selectedProviderId);
  }, [providers, selectedProviderId]);

  const visibleProviderSignature = useMemo(
    () =>
      visibleProviders
        .map((provider) => `${provider.id}:${provider.models.map((model) => model.id).join(",")}`)
        .join("|"),
    [visibleProviders],
  );
  const defaultExpandedProviderIds = useMemo(
    () => getDefaultExpandedModelSwitcherProviderIds(visibleProviders, selectedProviderId),
    // Cached by content signature: visibleProviders returns a new reference on every recompute, but the
    // expanded state must not reset when the content is identical (providers only refreshed their reference).
    // The signature already captures the content, so depend on signature + selectedProviderId and leave the
    // redundant visibleProviders reference out, or the signature would be pointless.
    [visibleProviderSignature, selectedProviderId],
  );

  useEffect(() => {
    setExpandedProviderIds(defaultExpandedProviderIds);
  }, [defaultExpandedProviderIds]);

  const currentProvider = useMemo(
    () =>
      visibleProviders.find((provider) =>
        sameNormalizedID(provider.id, selectedProviderId),
      ) ?? visibleProviders[0],
    [visibleProviders, selectedProviderId],
  );

  // useMemo: feeds the providerSections dependency list, so its own reference must be stable or the whole chain recomputes every render.
  const resolvedCurrentModel = useMemo(
    () => currentModel ?? findModelInProvider(currentProvider, selectedModelId),
    [currentModel, currentProvider, selectedModelId],
  );

  const addableProviderIds = useMemo(
    () => new Set(visibleProviders.filter((p) => supportsAddModels(p)).map((p) => p.id)),
    [visibleProviders],
  );
  const addableProviders = useMemo(
    () => visibleProviders.filter((p) => addableProviderIds.has(p.id)),
    [visibleProviders, addableProviderIds],
  );

  const normalizedQuery = query.trim().toLowerCase();
  const hasFilters = activeFilters.size > 0;

  const providerSections = useMemo<ProviderSection[]>(() => {
    return visibleProviders
      .map((provider) => {
        const providerName = getModelSwitcherProviderLabel(provider);
        const providerMatches = providerName
          .toLowerCase()
          .includes(normalizedQuery);
        const nextModels = [...provider.models];

        if (
          resolvedCurrentModel &&
          sameNormalizedID(provider.id, selectedProviderId) &&
          !nextModels.some((model) => model.id === resolvedCurrentModel.id)
        ) {
          nextModels.unshift(resolvedCurrentModel);
        }

        const filteredModels = sortProviderModels(nextModels, provider.kind)
          .filter((model) => modelMatchesQuery(model, normalizedQuery))
          .filter((model) => modelMatchesFilters(
            provider,
            model,
            activeFilters,
            capabilityProjector,
            requiredGenerationParameterId,
          ));
        const canAddModels = addableProviderIds.has(provider.id);

        // With a filter or query active, only model hits decide whether the section stays
        if (normalizedQuery || hasFilters) {
          if (!providerMatches && filteredModels.length === 0) {
            return null;
          }
          return {
            provider,
            providerName,
            models: filteredModels,
            canAddModels,
          };
        }

        if (filteredModels.length === 0 && !canAddModels) {
          return null;
        }

        return {
          provider,
          providerName,
          models: filteredModels,
          canAddModels,
        };
      })
      .filter((section): section is ProviderSection => section !== null);
  }, [
    activeFilters,
    addableProviderIds,
    hasFilters,
    normalizedQuery,
    requiredGenerationParameterId,
    resolvedCurrentModel,
    selectedModelId,
    selectedProviderId,
    visibleProviders,
    capabilityEvidenceTick,
    capabilityProjector,
  ]);

  const capabilityFilterCounts = useMemo(() => {
    const counts = Object.fromEntries(
      CAPABILITY_FILTERS.map((entry) => [entry.key, 0]),
    ) as Record<FilterKey, number>;
    for (const provider of visibleProviders) {
      for (const model of provider.models) {
        if (!modelMatchesQuery(model, normalizedQuery)) continue;
        for (const entry of CAPABILITY_FILTERS) {
          // When a generation parameter is required, the chip numbers must stay within "supports that
          // parameter" too, or they promise models that are not in the list once you click through.
          if (modelMatchesFilters(provider, model, new Set([entry.key]), capabilityProjector, requiredGenerationParameterId)) {
            counts[entry.key] += 1;
          }
        }
      }
    }
    return counts;
    // eslint-disable-next-line react-hooks/exhaustive-deps -- capabilityEvidenceTick is the expiry signal of the evidence TTL
  }, [visibleProviders, normalizedQuery, capabilityProjector, capabilityEvidenceTick, requiredGenerationParameterId]);

  const toggleFilter = (key: FilterKey) => {
    setActiveFilters((prev) => {
      const next = new Set(prev);
      if (next.has(key)) {
        next.delete(key);
      } else {
        next.add(key);
      }
      return next;
    });
  };

  const clearFilters = () => setActiveFilters(new Set());

  // useMemo: activeProvider is a dependency of activeProviderResolved / catalogGroups, so a stable
  // reference keeps the catalog chain from recomputing on every render.
  const activeProvider = useMemo(
    () =>
      view.kind === "browse"
        ? null
        : (providers.find((provider) =>
            sameNormalizedID(provider.id, view.providerId),
          ) ?? null),
    [view, providers],
  );

  // metadataTick, same reason: when the snapshot changes but the activeProvider reference does not, this
  // must refetch, or the model library sticks on the old snapshot (selectResolvedCatalog's LRU is already cleared).
  const activeProviderResolved = useMemo(
    () => (activeProvider ? selectResolvedCatalog(activeProvider) : null),
    [activeProvider, metadataTick],
  );

  const catalogSourceModels = useMemo(() => {
    if (!activeProviderResolved || view.kind !== "catalog") {
      return [];
    }

    return activeProviderResolved.catalog.filter((model) => !model.isEnabled);
  }, [activeProviderResolved, view.kind]);

  const catalogGroups = useMemo(() => {
    if (!activeProvider || !activeProviderResolved || view.kind !== "catalog") {
      return [];
    }

    return buildModelBrowserGroups({
      catalogModels: catalogSourceModels,
      popularitySourceModels: activeProviderResolved.catalog,
      query: catalogQuery,
      capFilter: null,
      sortBy: "recommended",
      providerKind: activeProvider.kind,
      providerLabel: getModelSwitcherProviderLabel(activeProvider),
      provider: activeProvider,
      capabilityProjector,
    });
  }, [activeProvider, activeProviderResolved, catalogQuery, catalogSourceModels, view.kind, capabilityProjector]);

  const catalogAllGroups = useMemo(() => {
    if (!activeProvider || !activeProviderResolved || view.kind !== "catalog") {
      return [];
    }

    return buildModelBrowserGroups({
      catalogModels: catalogSourceModels,
      popularitySourceModels: activeProviderResolved.catalog,
      query: "",
      capFilter: null,
      sortBy: "recommended",
      providerKind: activeProvider.kind,
      providerLabel: getModelSwitcherProviderLabel(activeProvider),
      provider: activeProvider,
      capabilityProjector,
    });
  }, [activeProvider, activeProviderResolved, catalogSourceModels, view.kind, capabilityProjector]);

  const selectedCatalogGroup = useMemo(
    () =>
      selectedCatalogGroupId
        ? (catalogAllGroups.find(
            (group) => group.id === selectedCatalogGroupId,
          ) ?? null)
        : null,
    [catalogAllGroups, selectedCatalogGroupId],
  );

  const scopedCatalogGroups = useMemo(
    () =>
      selectedCatalogGroupId
        ? catalogGroups.filter((group) => group.id === selectedCatalogGroupId)
        : catalogGroups,
    [catalogGroups, selectedCatalogGroupId],
  );

  const catalogShortcutGroups = useMemo(
    () => catalogAllGroups.slice(0, CATALOG_SHORTCUT_LIMIT),
    [catalogAllGroups],
  );

  // Presentation contract: whether to show the supplier directory follows the catalog data (several vendor
  // groups present), not a hardcoded check on provider.kind.
  const shouldShowCatalogSupplierDirectory = catalogAllGroups.length > 1;

  const catalogModelCount = useMemo(
    () =>
      scopedCatalogGroups.reduce(
        (total, group) => total + group.models.length,
        0,
      ),
    [scopedCatalogGroups],
  );

  const existingManualModel = useMemo(
    () =>
      activeProvider && manualModelId.trim()
        ? activeProvider.models.find((model) => model.id === manualModelId.trim())
        : undefined,
    [activeProvider, manualModelId],
  );

  const openAddView = (provider: Provider) => {
    setExpandedProviderIds(new Set([provider.id]));

    if (provider.kind === "relay") {
      setManualModelId("");
      setView({ kind: "manual", providerId: provider.id });
      return;
    }

    setCatalogQuery("");
    setSelectedCatalogGroupId(null);
    setView({ kind: "catalog", providerId: provider.id });
  };

  useEffect(() => {
    if (!selectedCatalogGroupId) return;
    if (catalogAllGroups.some((group) => group.id === selectedCatalogGroupId))
      return;
    setSelectedCatalogGroupId(null);
  }, [catalogAllGroups, selectedCatalogGroupId]);

  const returnToBrowse = () => {
    setCatalogQuery("");
    setSelectedCatalogGroupId(null);
    setManualModelId("");
    setView({ kind: "browse" });
  };

  const handleCatalogEnableAndSelect = (model: AIModel, provider: Provider) => {
    onEnableAndSelect(model, provider);
    returnToBrowse();
  };

  const handleManualSubmit = () => {
    if (!activeProvider) return;

    const trimmed = manualModelId.trim();
    if (!trimmed) return;

    if (existingManualModel) {
      onSelect(existingManualModel, activeProvider);
      returnToBrowse();
      return;
    }

    onAddManualAndSelect(trimmed, activeProvider);
    returnToBrowse();
  };

  return {
    browseSearchRef,
    catalogSearchRef,
    manualInputRef,
    listRef,

    view,
    setView,

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
    capabilityFilterCounts,
    addableProviders,
    capabilityProjector,

    catalogQuery,
    setCatalogQuery,
    selectedCatalogGroupId,
    setSelectedCatalogGroupId,
    expandedCatalogGroupIds,
    toggleCatalogGroup,

    activeProvider,
    catalogGroups,
    catalogAllGroups,
    scopedCatalogGroups,
    selectedCatalogGroup,
    catalogShortcutGroups,
    catalogModelCount,
    shouldShowCatalogSupplierDirectory,

    manualModelId,
    setManualModelId,
    existingManualModel,

    openAddView,
    returnToBrowse,
    handleCatalogEnableAndSelect,
    handleManualSubmit,
    onSelect,
  };
}
