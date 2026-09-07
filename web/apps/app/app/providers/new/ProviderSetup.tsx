"use client";

import React, { useState, useRef, useCallback, useEffect, useMemo } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useTranslations } from "next-intl";
import type { AIModel, Provider, ProviderAuthMode, ProviderSubscriptionCredential } from "@oriveo/shared";
import { formatApiKeyPreview } from "@oriveo/shared";
import type { ConfiguredProviderKind } from "@oriveo/config";
import {
  Button,
  BackArrowIcon,
  CloseIcon,
  EyeIcon,
  EyeOffIcon,
} from "@oriveo/ui";
import { useAppStore } from "../../../providers/StoreProvider";
import { getVanillaStore } from "../../../providers/StoreProvider";
import * as providerOps from "../../../lib/core/provider-ops";
import { validateOfficialProviderKey } from "../../../lib/core/providers/service";
import { PROVIDER_VALIDATION_MESSAGES } from "../../../lib/core/providers/validation-messages";
import { buildOfficialEnabledModels } from "../../../lib/core/providers/official-model-sync";
import type { CatalogMetadataInput } from "../../../lib/core/providers/catalog-resolver";
import { makeDefaultProviderInstanceName } from "../../../lib/core/providers/provider-display";
import type { ProviderError } from "../../../lib/core/providers/errors";
import { ProviderIcon } from "../../../components/ProviderIcon";
import {
  SetupHero,
  ProviderCategoryChips,
  ProviderShowcaseSection,
  CustomRelayEntry,
  LocalComputeEntry,
  type ProviderCategory,
} from "./ProviderCard";
import { createCanonicalUUID, createDeterministicProviderId } from "../../../lib/utils/id-utils";
import { isPrintableAsciiKey } from "../../../lib/utils/api-key-validation";
import { getApiKeyInputProps } from "../../../lib/forms/api-key-input-props";
import {
  getGrokSubscriptionAvailability,
  getOpenAISubscriptionAvailability,
  getMetadataSnapshot,
  hasPublicProviderConfigSource,
  initMetadata,
  listPublicProviderConfigs,
  refreshMetadata,
} from "../../../lib/core/metadata/metadata-client";
import { ProviderConnectionModePicker } from "../../../components/providers/ProviderConnectionModePicker";
import { GrokSubscriptionAuthorizationDialog } from "../../../components/providers/GrokSubscriptionAuthorizationDialog";
import { OpenAISubscriptionAuthorizationDialog } from "../../../components/providers/OpenAISubscriptionAuthorizationDialog";
import { buildGrokSubscriptionModels } from "../../../lib/core/providers/grok-subscription-catalog";
import { grokSubscriptionErrorToValidationMessage } from "../../../lib/core/providers/grok-subscription";
import { fetchGrokSubscriptionModels } from "../../../lib/core/providers/grok-subscription";
import { buildOpenAISubscriptionModels } from "../../../lib/core/providers/openai-subscription-catalog";
import { openAISubscriptionErrorToValidationMessage } from "../../../lib/core/providers/openai-subscription";
import { fetchOpenAISubscriptionModels } from "../../../lib/core/providers/openai-subscription";
import subscriptionStyles from "../../../components/providers/ProviderSubscription.module.css";
import { resolveProviderSetupCatalog } from "./provider-config-catalog";
import { OfficialEndpointSelector } from "../../../components/providers/OfficialEndpointSelector";
import {
  getOfficialEndpointDescriptionTranslationKey,
  getOfficialEndpointOptionTranslationKey,
  isOfficialEndpointProvider,
} from "../../../components/providers/official-endpoint-utils";
import {
  trackEvent,
  telemetryProviderKind,
  ProviderSetupStep,
  TELEMETRY_KIND_UNSPECIFIED,
  providerKeyValidatedProperties,
  providerSetupAbandonedProperties,
  ProviderSetupSurface,
  TelemetryAuthMode,
  type ProviderSetupEntryPointValue,
  type ProviderSetupStepValue,
} from "../../../lib/core/telemetry";
import { markRelayHandoff } from "./relay-handoff";
import { showToast } from "../../../components/Toast";
import styles from "./ProviderSetup.module.css";

type SetupState =
  | "idle"
  | "validating"
  | "syncing"
  | "success"
  | "syncFailed"
  | "keyInvalid"
  | "networkError";

const RELAY_SETUP_ROUTE = "/providers/relay/new";

export function ProviderSetup() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const t = useTranslations("pages.providerSetup");
  const tc = useTranslations("common");
  const te = useTranslations("errors");
  const providers = useAppStore((s) => s.providers);
  const setHasCompletedOnboarding = useAppStore(
    (s) => s.setHasCompletedOnboarding,
  );

  const [providerConfigs, setProviderConfigs] = useState(
    () => null as ReturnType<typeof listPublicProviderConfigs> | null,
  );
  const providerCatalog = resolveProviderSetupCatalog(providerConfigs);
  // providerConfigs gates the check; using it as a dependency recomputes after a metadata refresh.
  const grokSubscription = useMemo(
    () => getGrokSubscriptionAvailability(),
    [providerConfigs],
  );
  const openAISubscription = useMemo(
    () => getOpenAISubscriptionAvailability(),
    [providerConfigs],
  );
  // Pick a provider first, then fill in the key inline: nothing is selected initially and the key field only appears after a selection.
  const [selectedKind, setSelectedKind] = useState<ConfiguredProviderKind | null>(null);
  const [selectedCategory, setSelectedCategory] = useState<ProviderCategory>("all");
  const [apiKey, setApiKey] = useState("");
  const [showKey, setShowKey] = useState(false);
  const [baseURL, setBaseURL] = useState("");
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [selectedRegion, setSelectedRegion] = useState("sg");
  const [state, setState] = useState<SetupState>("idle");
  const [error, setError] = useState<ProviderError | null>(null);
  const [keyCharsError, setKeyCharsError] = useState<string | null>(null);
  const [newProviderId, setNewProviderId] = useState<string | null>(null);
  // Additional-instance mode: the default instance uses a deterministic id. After the user
  // explicitly picks "add another account" while already connected, this flips to true and the
  // connection gets a random id instead (auto-named "X 2").
  const [additionalInstanceMode, setAdditionalInstanceMode] = useState(false);
  // Auth mode. When the server sends nothing, or the kill switch is off, the whole selector is
  // hidden and the flow is unchanged. One piece of state serves both links (Grok and Codex),
  // since only one provider kind can be selected at a time.
  const [subscriptionAuthMode, setSubscriptionAuthMode] = useState<ProviderAuthMode>("apiKey");
  const [showGrokSubscriptionDialog, setShowGrokSubscriptionDialog] = useState(false);
  const [showOpenAISubscriptionDialog, setShowOpenAISubscriptionDialog] = useState(false);
  const initialKindParamRef = useRef(false);

  const keyInputRef = useRef<HTMLInputElement>(null);
  const defaults = selectedKind
    ? providerCatalog.defaultsByKind[selectedKind]
    : null;
  const selectedProviderConfig = selectedKind
    ? providerCatalog.configsByKind[selectedKind]
    : null;
  const selectedDisplayName = selectedKind
    ? (providerCatalog.providers.find((p) => p.kind === selectedKind)?.displayName ??
       defaults?.displayName ??
       selectedKind)
    : "";
  const selectedRegionOptions = selectedProviderConfig?.regionOptions ?? [];
  const localizedEndpointOptions = useMemo(() => {
    if (!selectedKind) {
      return [];
    }

    return selectedRegionOptions.map((option) => {
      if (!isOfficialEndpointProvider(selectedKind)) {
        return option;
      }

      const translationKey = getOfficialEndpointOptionTranslationKey(
        selectedKind,
        option.id,
      );
      return {
        ...option,
        label: translationKey ? t(translationKey) : option.label,
      };
    });
  }, [selectedKind, selectedRegionOptions, t]);
  const officialEndpointDescription = useMemo(() => {
    if (
      !selectedKind
      || !isOfficialEndpointProvider(selectedKind)
      || localizedEndpointOptions.length === 0
    ) {
      return null;
    }

    return t(getOfficialEndpointDescriptionTranslationKey(selectedKind));
  }, [localizedEndpointOptions.length, selectedKind, t]);
  const selectedAPIKeyHelpURL =
    localizedEndpointOptions.find((option) => option.id === selectedRegion)?.apiKeyHelpURL
    ?? defaults?.keyHelpUrl;
  const isFirstProvider = providers.length === 0;
  const entryPoint = useMemo<ProviderSetupEntryPointValue>(() => {
    const requested = searchParams.get('entry_point');
    if (
      requested === 'onboarding'
      || requested === 'providers'
      || requested === 'model_picker'
      || requested === 'skill_edit'
    ) {
      return requested;
    }
    return isFirstProvider ? 'onboarding' : 'providers';
  }, [isFirstProvider, searchParams]);
  // State read inside the unmount callback is a stale closure, so the latest progress goes through a ref.
  const setupStateRef = useRef<{
    kind: ConfiguredProviderKind | null;
    reachedStep: ProviderSetupStepValue;
    endpoint: string;
    completed: boolean;
    handedOffToRelay: boolean;
    entryPoint: ProviderSetupEntryPointValue;
    isFirstProvider: boolean;
    connectionAttempts: number;
    lastErrorCode: string;
  }>({
    kind: null,
    reachedStep: ProviderSetupStep.kindPicker,
    endpoint: '',
    completed: false,
    handedOffToRelay: false,
    entryPoint,
    isFirstProvider,
    connectionAttempts: 0,
    lastErrorCode: '',
  });
  const setupStartedRef = useRef(false);

  // The endpoint that will actually be used (region first, then a custom baseURL, then the
  // provider default). Used both for registration and for the abandoned event: an official
  // provider pointed at the wrong regional endpoint fails just the same, and the address is the
  // first thing to look at.
  const effectiveBaseURL = useMemo(() => {
    if (!defaults) return '';
    return selectedRegionOptions.length > 0
      ? (selectedRegionOptions.find((r) => r.id === selectedRegion)?.baseURL ?? defaults.defaultBaseURL)
      : baseURL || defaults.defaultBaseURL;
  }, [defaults, selectedRegionOptions, selectedRegion, baseURL]);

  useEffect(() => {
    setupStateRef.current.endpoint = effectiveBaseURL;
  }, [effectiveBaseURL]);

  useEffect(() => {
    setupStateRef.current.entryPoint = entryPoint;
    setupStateRef.current.isFirstProvider = isFirstProvider;
  }, [entryPoint, isFirstProvider]);

  // Opening the setup page counts as the start of the flow, so the denominator is "opened the
  // setup page" and the largest drop-off, leaving without picking anyone, has a started event to
  // pair with. Wait until providers have hydrated, otherwise the still-empty array turns
  // is_first_provider into a false true.
  useEffect(() => {
    if (setupStartedRef.current) return;
    if (!providers) return;
    setupStartedRef.current = true;
    const requestedKind = searchParams.get("kind");
    trackEvent('provider_setup_started', {
      provider_kind: requestedKind
        ? telemetryProviderKind(requestedKind)
        : TELEMETRY_KIND_UNSPECIFIED,
      is_first_provider: providers.length === 0,
      is_relay: requestedKind === "relay",
      entry_point: entryPoint,
    });
  }, [entryPoint, providers, searchParams]);

  // Unmounting means leaving the setup flow. Completing, or handing off to the relay page, is not abandonment.
  useEffect(() => {
    return () => {
      const s = setupStateRef.current;
      if (!setupStartedRef.current || s.completed || s.handedOffToRelay) return;
      trackEvent('provider_setup_abandoned', providerSetupAbandonedProperties({
        providerKind: s.kind ? telemetryProviderKind(s.kind) : TELEMETRY_KIND_UNSPECIFIED,
        stepReached: s.reachedStep,
        endpoint: s.endpoint,
        entryPoint: s.entryPoint,
        isFirstProvider: s.isFirstProvider,
        connectionAttempts: s.connectionAttempts,
        lastErrorCode: s.lastErrorCode,
      }));
    };
  }, []);

  const handleSelectKind = useCallback((kind: ConfiguredProviderKind) => {
    setSelectedKind(kind);
    setApiKey("");
    setShowKey(false);
    setBaseURL("");
    setSelectedRegion(
      providerCatalog.configsByKind[kind].regionOptions[0]?.id ?? "sg",
    );
    setError(null);
    setState("idle");
    setAdditionalInstanceMode(false);
    setSubscriptionAuthMode("apiKey");
    setupStateRef.current = {
      ...setupStateRef.current,
      kind,
      reachedStep: ProviderSetupStep.kindSelected,
      connectionAttempts: 0,
      lastErrorCode: '',
    };
    setTimeout(() => keyInputRef.current?.focus(), 50);
  }, [providerCatalog.configsByKind]);

  const handleOpenCustomEndpoint = useCallback(() => {
    setupStateRef.current.handedOffToRelay = true;
    markRelayHandoff({ entryPoint, isFirstProvider });
    router.push(RELAY_SETUP_ROUTE);
  }, [entryPoint, isFirstProvider, router]);

  const handleOpenLocalCompute = useCallback(() => {
    setupStateRef.current.handedOffToRelay = true;
    markRelayHandoff({ entryPoint, isFirstProvider });
    router.push(`${RELAY_SETUP_ROUTE}?mode=local`);
  }, [entryPoint, isFirstProvider, router]);

  useEffect(() => {
    let cancelled = false;

    const applyProviderConfigs = () => {
      if (cancelled) return;
      setProviderConfigs(
        hasPublicProviderConfigSource() ? listPublicProviderConfigs() : null,
      );
    };

    initMetadata()
      .then(async () => {
        applyProviderConfigs();
        await refreshMetadata().catch(() => {});
        applyProviderConfigs();
      })
      .catch(() => {});

    return () => {
      cancelled = true;
    };
  }, []);

  // Preselection only handles the ?kind= query parameter (relay jumps to its own page, a known
  // provider gets selected). No provider is selected by default: the landing page is a showcase
  // until the user picks one.
  useEffect(() => {
    if (initialKindParamRef.current) return;
    const requestedKind = searchParams.get("kind");
    if (!requestedKind) return;

    if (requestedKind === "relay") {
      initialKindParamRef.current = true;
      setupStateRef.current.handedOffToRelay = true;
      markRelayHandoff({ entryPoint, isFirstProvider });
      router.push(RELAY_SETUP_ROUTE);
      return;
    }

    if (providerCatalog.providers.some((provider) => provider.kind === requestedKind)) {
      initialKindParamRef.current = true;
      handleSelectKind(requestedKind as ConfiguredProviderKind);
    }
  }, [entryPoint, handleSelectKind, isFirstProvider, providerCatalog.providers, searchParams, router]);

  // The selected provider is gone from the latest catalog, so clear the selection and go back to the showcase.
  useEffect(() => {
    if (
      selectedKind &&
      providerCatalog.providers.length > 0 &&
      !providerCatalog.providers.some((provider) => provider.kind === selectedKind)
    ) {
      setSelectedKind(null);
      setupStateRef.current = {
        ...setupStateRef.current,
        kind: null,
        reachedStep: ProviderSetupStep.kindPicker,
        endpoint: '',
        connectionAttempts: 0,
        lastErrorCode: '',
      };
    }
  }, [providerCatalog.providers, selectedKind]);

  useEffect(() => {
    if (!selectedKind || selectedRegionOptions.length === 0) {
      return;
    }

    if (!selectedRegionOptions.some((region) => region.id === selectedRegion)) {
      setSelectedRegion(selectedRegionOptions[0]?.id ?? "sg");
    }
  }, [selectedKind, selectedRegion, selectedRegionOptions]);

  const handleBack = useCallback(() => {
    if (isFirstProvider) {
      router.push("/welcome");
      return;
    }
    router.back();
  }, [isFirstProvider, router]);

  const handleConnect = useCallback(async () => {
    if (!selectedKind || !defaults) return;

    // Read the latest value from the DOM to avoid the race where onPaste closes over stale state.
    const trimmedKey = (keyInputRef.current?.value ?? apiKey).trim();
    if (!trimmedKey) return;
    setupStateRef.current.connectionAttempts += 1;

    // Prevent fetch() from throwing synchronously on a header containing non-Latin-1 characters (pasted keys often carry zero-width or full-width spaces).
    if (!isPrintableAsciiKey(trimmedKey)) {
      setupStateRef.current.lastErrorCode = 'invalid_key_characters';
      setKeyCharsError(tc("apiKeyInvalidChars"));
      setState("idle");
      return;
    }

    setError(null);
    setKeyCharsError(null);
    setState("validating");
    setupStateRef.current = {
      ...setupStateRef.current,
      kind: selectedKind,
      reachedStep: ProviderSetupStep.submitting,
    };

    try {
      const effectiveBase = effectiveBaseURL;

      // Refresh metadata so the canonical catalog is current; awaited so a stale catalog is not used.
      await refreshMetadata().catch(() => {});

      // The default or first instance gets a deterministic id (derived from kind and region, so
      // writes from several clients merge); an explicitly added extra account gets a random id.
      const regionId =
        selectedRegionOptions.length > 0 ? selectedRegion : "";
      const id = additionalInstanceMode
        ? createCanonicalUUID()
        : await createDeterministicProviderId(selectedKind, regionId);
      setNewProviderId(id);

      // The catalog for official providers comes from metadata, never from the adapter syncModels return value.
      const metadata = getMetadataSnapshot() as CatalogMetadataInput | null;
      const build = buildOfficialEnabledModels(
        selectedKind,
        metadata,
        {},
        { repairLegacyAutoEnabledAll: true },
      );

      if (build.models.length === 0) {
        // Empty catalog (metadata not loaded yet, or this provider has no models): take the syncFailed branch.
        throw {
          kind: "emptyModelCatalog",
          message: "The model catalog is empty. Please try again later or enter a model ID manually.",
        } as ProviderError;
      }

      // BYOK key validation never blocks saving: an invalid key is still stored and shown in red,
      // unverified gets a grey hint. The three-way result (valid/invalid/unverified) is resolved
      // through the Next runtime proxy.
      setState("syncing");
      const validation = await validateOfficialProviderKey(
        selectedKind,
        trimmedKey,
        effectiveBase,
      );

      const status: Provider["status"] =
        validation === "invalid"
          ? { kind: "issue", message: PROVIDER_VALIDATION_MESSAGES.invalidKey }
          : { kind: "connected" };
      const lastError =
        validation === "invalid"
          ? PROVIDER_VALIDATION_MESSAGES.invalidKey
          : validation === "unverified"
            ? PROVIDER_VALIDATION_MESSAGES.unverified
            : undefined;

      const provider: Provider = {
        id,
        kind: selectedKind,
        status,
        models: build.models,
        // Official providers do not store catalogModels; metadata resolves them dynamically.
        catalogModels: [],
        lastCheckedAt: new Date().toISOString(),
        lastError,
        apiKey: trimmedKey,
        apiKeyPreview: formatApiKeyPreview(trimmedKey),
        baseURLText: effectiveBase,
        customName: makeDefaultProviderInstanceName(selectedKind, providers),
      };

      await providerOps.addProvider(getVanillaStore(), provider);
      setHasCompletedOnboarding(true);

      // BYOK key validation feedback, which never blocks: the provider is already stored, so this
      // is only a one-off toast before moving on. VALID shows nothing and goes straight through,
      // INVALID shows a red "key looks invalid", UNVERIFIED shows a soft "could not verify". The
      // detail page's Verify action is the escape hatch.
      if (validation === "invalid") {
        showToast(te("validation.savedButInvalid"));
      } else if (validation === "unverified") {
        showToast(te("validation.unverified"));
      }

      // provider_key_validated shares one provider_kind/success/error_code contract across clients,
      // so the provider setup funnel dashboard has an unbroken web segment.
      trackEvent('provider_key_validated', providerKeyValidatedProperties({
        providerKind: telemetryProviderKind(selectedKind),
        // success reflects the real validation result (valid and unverified count as true, invalid as false).
        success: validation !== "invalid",
        // On INVALID the provider is still stored as an escape hatch, but the dashboard has to show that validation failed.
        errorCode: validation === "invalid" ? "invalid_key" : null,
        endpoint: effectiveBase,
        entryPoint: setupStateRef.current.entryPoint,
        isFirstProvider: setupStateRef.current.isFirstProvider,
        connectionAttempts: setupStateRef.current.connectionAttempts,
        setupSurface: ProviderSetupSurface.providerSetup,
      }));
      setState("success");
      setupStateRef.current = { ...setupStateRef.current, kind: selectedKind, completed: true };

      setTimeout(() => {
        router.push(isFirstProvider ? "/chat" : "/providers");
      }, 300);
    } catch (err) {
      const pe = err as ProviderError;
      const errorCode = pe?.kind ?? 'unknown';
      setupStateRef.current.lastErrorCode = errorCode;
      setError(pe);
      trackEvent('provider_key_validated', providerKeyValidatedProperties({
        providerKind: telemetryProviderKind(selectedKind),
        success: false,
        errorCode,
        // On failure the endpoint is the first thing to look at: a wrong regional endpoint fails
        // just the same. effectiveBase is scoped inside the try, so use the mirror kept in sync
        // for the abandoned event.
        endpoint: setupStateRef.current.endpoint,
        entryPoint: setupStateRef.current.entryPoint,
        isFirstProvider: setupStateRef.current.isFirstProvider,
        connectionAttempts: setupStateRef.current.connectionAttempts,
        setupSurface: ProviderSetupSurface.providerSetup,
      }));
      if (pe.kind === "invalidKey") {
        setState("keyInvalid");
      } else if (pe.kind === "network") {
        setState("networkError");
      } else {
        setState("syncFailed");
      }
    }
  }, [
    apiKey,
    selectedKind,
    selectedRegion,
    effectiveBaseURL,
    defaults,
    selectedRegionOptions,
    additionalInstanceMode,
    setHasCompletedOnboarding,
    isFirstProvider,
    router,
    providers,
    tc,
    te,
  ]);

  /**
   * Store the provider after a successful subscription authorization.
   *
   * No key validation here: `validateOfficialProviderKey` hits the API-key mode default endpoint
   * (api.x.ai), and a subscription token sent there always fails, which would flag a connection
   * that just authorized successfully as an issue. A completed OAuth flow is already stronger
   * evidence that upstream accepted the identity than a probe request would be.
   */
  const completeGrokSubscriptionSetup = useCallback(async (credential: ProviderSubscriptionCredential) => {
    setShowGrokSubscriptionDialog(false);
    setupStateRef.current.connectionAttempts += 1;
    setError(null);
    setState("syncing");
    try {
      const regionId = selectedRegionOptions.length > 0 ? selectedRegion : "";
      const id = additionalInstanceMode
        ? createCanonicalUUID()
        : await createDeterministicProviderId("grok", regionId);
      setNewProviderId(id);

      // The subscription catalog must be fetched fresh. On failure clear it and say so rather than
      // keeping the API-key catalog: that would hand the user a list of dead entries where every
      // selection fails with a confusing error.
      const catalog = await fetchGrokSubscriptionModels(credential.accessToken);
      const models: AIModel[] = catalog.ok
        ? buildGrokSubscriptionModels(catalog.value, t("grokSubscription.modelSummary"))
        : [];

      const provider: Provider = {
        id,
        kind: "grok",
        // A failed catalog fetch is an issue, reported with the same status as the equivalent
        // failure in `resyncGrokSubscriptionProvider`. Writing connected would hide the recovery
        // card (shown only for issue and needsKey) and leave the user with a "connected" instance
        // that has zero models and no explanation. Successful authorization does not mean the
        // catalog backend is reachable, and that real reason needs somewhere to land.
        status: catalog.ok
          ? { kind: "connected" }
          : { kind: "issue", message: grokSubscriptionErrorToValidationMessage(catalog.error) },
        models,
        catalogModels: [],
        lastCheckedAt: new Date().toISOString(),
        ...(catalog.ok
          ? {}
          : { lastError: grokSubscriptionErrorToValidationMessage(catalog.error) }),
        // apiKey stays empty: `grokSubscription` is the single source of truth for subscription
        // credentials, and storing the token in two places would eventually make it unclear which
        // copy is current, since renewal only updates one.
        apiKey: "",
        apiKeyPreview: "",
        baseURLText: effectiveBaseURL || defaults?.defaultBaseURL,
        customName: makeDefaultProviderInstanceName("grok", providers),
        authMode: "subscription",
        grokSubscription: credential,
      };

      await providerOps.addProvider(getVanillaStore(), provider);
      setHasCompletedOnboarding(true);
      trackEvent('provider_key_validated', providerKeyValidatedProperties({
        providerKind: telemetryProviderKind("grok"),
        success: true,
        endpoint: effectiveBaseURL || defaults?.defaultBaseURL,
        entryPoint: setupStateRef.current.entryPoint,
        isFirstProvider: setupStateRef.current.isFirstProvider,
        connectionAttempts: setupStateRef.current.connectionAttempts,
        authMode: TelemetryAuthMode.subscription,
        setupSurface: ProviderSetupSurface.providerSetup,
      }));
      setState("success");
      setupStateRef.current = { ...setupStateRef.current, kind: "grok", completed: true };
      setTimeout(() => {
        router.push(isFirstProvider ? "/chat" : "/providers");
      }, 300);
    } catch (err) {
      const pe = err as ProviderError;
      setupStateRef.current.lastErrorCode = pe?.kind ?? 'unknown';
      setError(pe);
      setState("syncFailed");
      trackEvent('provider_key_validated', providerKeyValidatedProperties({
        providerKind: telemetryProviderKind("grok"),
        success: false,
        errorCode: setupStateRef.current.lastErrorCode,
        endpoint: effectiveBaseURL || defaults?.defaultBaseURL,
        entryPoint: setupStateRef.current.entryPoint,
        isFirstProvider: setupStateRef.current.isFirstProvider,
        connectionAttempts: setupStateRef.current.connectionAttempts,
        authMode: TelemetryAuthMode.subscription,
        setupSurface: ProviderSetupSurface.providerSetup,
      }));
    }
  }, [
    additionalInstanceMode,
    defaults,
    effectiveBaseURL,
    isFirstProvider,
    providers,
    router,
    selectedRegion,
    selectedRegionOptions.length,
    setHasCompletedOnboarding,
    t,
  ]);

  /**
   * Store the provider after a successful Codex (ChatGPT subscription) authorization.
   *
   * Structurally identical to the Grok path, with two differences:
   *   1. The catalog fetch must be handed the `accountID` that was resolved and checked for
   *      emptiness while exchanging the token. Re-deriving it from the access token yields
   *      undefined, which surfaces as "could not fetch the model list" right after a successful
   *      authorization.
   *   2. Key validation is skipped for the same reason: `validateOfficialProviderKey` hits
   *      api.openai.com, where a subscription token always fails and would flag the connection as
   *      an issue.
   */
  const completeOpenAISubscriptionSetup = useCallback(async (credential: ProviderSubscriptionCredential) => {
    setShowOpenAISubscriptionDialog(false);
    setupStateRef.current.connectionAttempts += 1;
    setError(null);
    setState("syncing");
    try {
      const regionId = selectedRegionOptions.length > 0 ? selectedRegion : "";
      const id = additionalInstanceMode
        ? createCanonicalUUID()
        : await createDeterministicProviderId("openAI", regionId);
      setNewProviderId(id);

      // The subscription catalog must be fetched fresh. On failure clear it and say so rather than
      // keeping the API-key catalog: those api.openai.com models do not exist on the Codex backend,
      // so keeping them would leave a list of dead entries.
      const catalog = await fetchOpenAISubscriptionModels(
        credential.accessToken,
        credential.accountID ?? "",
      );
      const models: AIModel[] = catalog.ok
        ? buildOpenAISubscriptionModels(catalog.value, t("openaiSubscription.modelSummary"))
        : [];

      const provider: Provider = {
        id,
        kind: "openAI",
        // A failed catalog fetch is an issue, reported with the same status as the equivalent
        // failure in `resyncOpenAISubscriptionProvider`. Writing connected would hide the recovery
        // card (shown only for issue and needsKey) and leave the user with a "connected" instance
        // that has zero models and no explanation. Successful authorization does not mean the
        // catalog backend is reachable, and that real reason needs somewhere to land.
        status: catalog.ok
          ? { kind: "connected" }
          : { kind: "issue", message: openAISubscriptionErrorToValidationMessage(catalog.error) },
        models,
        catalogModels: [],
        lastCheckedAt: new Date().toISOString(),
        ...(catalog.ok
          ? {}
          : { lastError: openAISubscriptionErrorToValidationMessage(catalog.error) }),
        // apiKey stays empty: `openAISubscription` is the single source of truth for subscription
        // credentials, and storing the token in two places would eventually make it unclear which
        // copy is current, since renewal only updates one.
        apiKey: "",
        apiKeyPreview: "",
        baseURLText: effectiveBaseURL || defaults?.defaultBaseURL,
        customName: makeDefaultProviderInstanceName("openAI", providers),
        authMode: "subscription",
        openAISubscription: credential,
      };

      await providerOps.addProvider(getVanillaStore(), provider);
      setHasCompletedOnboarding(true);
      trackEvent('provider_key_validated', providerKeyValidatedProperties({
        providerKind: telemetryProviderKind("openAI"),
        success: true,
        endpoint: effectiveBaseURL || defaults?.defaultBaseURL,
        entryPoint: setupStateRef.current.entryPoint,
        isFirstProvider: setupStateRef.current.isFirstProvider,
        connectionAttempts: setupStateRef.current.connectionAttempts,
        authMode: TelemetryAuthMode.subscription,
        setupSurface: ProviderSetupSurface.providerSetup,
      }));
      setState("success");
      setupStateRef.current = { ...setupStateRef.current, kind: "openAI", completed: true };
      setTimeout(() => {
        router.push(isFirstProvider ? "/chat" : "/providers");
      }, 300);
    } catch (err) {
      const pe = err as ProviderError;
      setupStateRef.current.lastErrorCode = pe?.kind ?? 'unknown';
      setError(pe);
      setState("syncFailed");
      trackEvent('provider_key_validated', providerKeyValidatedProperties({
        providerKind: telemetryProviderKind("openAI"),
        success: false,
        errorCode: setupStateRef.current.lastErrorCode,
        endpoint: effectiveBaseURL || defaults?.defaultBaseURL,
        entryPoint: setupStateRef.current.entryPoint,
        isFirstProvider: setupStateRef.current.isFirstProvider,
        connectionAttempts: setupStateRef.current.connectionAttempts,
        authMode: TelemetryAuthMode.subscription,
        setupSurface: ProviderSetupSurface.providerSetup,
      }));
    }
  }, [
    additionalInstanceMode,
    defaults,
    effectiveBaseURL,
    isFirstProvider,
    providers,
    router,
    selectedRegion,
    selectedRegionOptions.length,
    setHasCompletedOnboarding,
    t,
  ]);

  const isWorking = state === "validating" || state === "syncing";
  const showStatusSection =
    isWorking || (state === "syncFailed" && Boolean(newProviderId));
  // Already-connected guard: when the selected kind already has a provider, do not silently
  // overwrite it or store a duplicate; make the user choose between managing the existing one and
  // adding another account.
  const existingSameKind = selectedKind
    ? providers.find((p) => p.kind === selectedKind)
    : undefined;
  const showAlreadyConnectedGuard =
    Boolean(existingSameKind) && !additionalInstanceMode;
  const isAggregator = selectedProviderConfig?.category === "aggregator";
  const directProviders = providerCatalog.providers.filter((p) => p.category === "direct");
  const aggregatorProviders = providerCatalog.providers.filter((p) => p.category === "aggregator");
  const showDirect = selectedCategory === "all" || selectedCategory === "direct";
  const showAggregators = selectedCategory === "all" || selectedCategory === "aggregators";
  // The choice only appears when the server sends it and the kill switch has not turned it off.
  // When disabled, already-connected instances keep their explanatory copy (owned by the detail
  // page) and the setup entry offers no subscription option.
  // Both links resolve their own availability and collapse into a single `subscriptionKind`, since
  // only one provider can be selected at a time. The selector, the connection panel, the CTA
  // suppression and the dialogs all read that one value instead of each carrying parallel
  // conditions, which is exactly where a missed branch hides.
  const subscriptionKind: "grok" | "openAI" | null =
    selectedKind === "grok" && grokSubscription.state === "available"
      ? "grok"
      : selectedKind === "openAI" && openAISubscription.state === "available"
        ? "openAI"
        : null;
  const subscriptionNamespace =
    subscriptionKind === "openAI" ? "openaiSubscription" : "grokSubscription";
  const showsSubscriptionModePicker = subscriptionKind !== null;
  const usesSubscriptionFlow =
    showsSubscriptionModePicker && subscriptionAuthMode === "subscription";
  const canContinue =
    selectedCategory !== "custom" &&
    Boolean(selectedKind) &&
    !showAlreadyConnectedGuard &&
    !usesSubscriptionFlow &&
    apiKey.trim().length > 0 &&
    !isWorking;

  return (
    <div className={styles.page}>
      <div className={styles.header}>
        <button
          className={styles.backBtn}
          onClick={handleBack}
          aria-label={tc("back")}
        >
          <BackArrowIcon />
        </button>
        <h1 className={styles.title}>{t("title")}</h1>
      </div>

      {error && (
        <div
          className={styles.errorBanner}
          role="alert"
          data-testid="provider-setup-error-banner"
        >
          <div className={styles.errorBannerCard}>
            <div className={styles.errorBannerBody}>
              <div className={styles.errorBannerIcon} aria-hidden="true">
                !
              </div>
              <div className={styles.errorBannerCopy}>
                <p className={styles.errorBannerTitle}>{te(`${error.kind}.title`)}</p>
                <p className={styles.errorBannerMessage}>{te(`${error.kind}.message`)}</p>
              </div>
            </div>
            <button
              type="button"
              className={styles.errorBannerDismiss}
              aria-label={tc("close")}
              data-testid="provider-setup-error-dismiss"
              onClick={() => setError(null)}
            >
              <CloseIcon size={16} />
            </button>
          </div>
        </div>
      )}

      {/* Status area */}
      {showStatusSection && (
        <div className={styles.statusSection}>
          {isWorking && (
            <div className={styles.progress}>
              <div className={styles.spinner} />
              {t("statusValidatingAndSyncing")}
            </div>
          )}

          {state === "syncFailed" && newProviderId && (
            <button
              className={styles.manualLink}
              onClick={() =>
                router.push(`/providers/${newProviderId}/manual-model`)
              }
            >
              {t("manualModelEntry")}
            </button>
          )}
        </div>
      )}

      <div className={styles.setupBody}>
        <SetupHero />

        <ProviderCategoryChips selected={selectedCategory} onSelect={setSelectedCategory} />

        {selectedCategory === "custom" ? (
          <div className={styles.customEntries}>
            <LocalComputeEntry onTap={handleOpenLocalCompute} />
            <CustomRelayEntry onTap={handleOpenCustomEndpoint} />
          </div>
        ) : (
          <>
            {showDirect && (
              <ProviderShowcaseSection
                label={t("directProvidersTitle")}
                providers={directProviders}
                selectedKind={selectedKind}
                onSelect={(kind) => handleSelectKind(kind as ConfiguredProviderKind)}
              />
            )}

            {showAggregators && (
              <ProviderShowcaseSection
                label={t("categoryAggregators")}
                providers={aggregatorProviders}
                selectedKind={selectedKind}
                onSelect={(kind) => handleSelectKind(kind as ConfiguredProviderKind)}
              />
            )}

            {/* Fill the key inline once a provider is selected */}
            {selectedKind && defaults && (
              <div className={styles.connectCard}>
                <div className={styles.connectHeader}>
                  <span className={styles.connectLogo} aria-hidden="true">
                    <ProviderIcon kind={selectedKind} size={32} />
                  </span>
                  <div className={styles.connectHeaderText}>
                    <p className={styles.connectTitle}>
                      {t("connectNamed", { provider: selectedDisplayName })}
                    </p>
                    <p className={styles.connectSubtitle}>{t("enterKeySubtitle")}</p>
                  </div>
                </div>

                {showAlreadyConnectedGuard && existingSameKind ? (
                  <div
                    className={styles.alreadyConnected}
                    data-testid="provider-already-connected-guard"
                  >
                    <p className={styles.alreadyConnectedText}>
                      {t("kindAlreadyConnected", { provider: selectedDisplayName })}
                    </p>
                    <div className={styles.alreadyConnectedActions}>
                      <button
                        type="button"
                        className={styles.alreadyConnectedManage}
                        data-testid="provider-manage-existing"
                        onClick={() => router.push(`/providers/${existingSameKind.id}`)}
                      >
                        {t("manageExisting")}
                      </button>
                      <button
                        type="button"
                        className={styles.alreadyConnectedAdd}
                        data-testid="provider-add-another"
                        onClick={() => {
                          setAdditionalInstanceMode(true);
                          setTimeout(() => keyInputRef.current?.focus(), 50);
                        }}
                      >
                        {t("addAnotherAccount")}
                      </button>
                    </div>
                  </div>
                ) : (
                <>
                {showsSubscriptionModePicker && subscriptionKind && (
                  <ProviderConnectionModePicker
                    mode={subscriptionAuthMode}
                    onChange={setSubscriptionAuthMode}
                    namespace={`pages.providerSetup.${subscriptionNamespace}`}
                    testIdPrefix={subscriptionKind === "openAI" ? "openai" : "grok"}
                  />
                )}

                {usesSubscriptionFlow ? (
                  <div className={subscriptionStyles.connectPanel}>
                    <p className={subscriptionStyles.connectHint}>
                      {t(`${subscriptionNamespace}.connectHint`)}
                    </p>
                    <Button
                      onClick={() =>
                        subscriptionKind === "openAI"
                          ? setShowOpenAISubscriptionDialog(true)
                          : setShowGrokSubscriptionDialog(true)
                      }
                      disabled={isWorking}
                      data-testid={
                        subscriptionKind === "openAI"
                          ? "openai-subscription-connect"
                          : "grok-subscription-connect"
                      }
                    >
                      {isWorking ? tc('loading') : t(`${subscriptionNamespace}.signIn`)}
                    </Button>
                  </div>
                ) : (
                <>
                <div className={styles.keyRow}>
                  <div className={styles.keyInputWrap}>
                    <input
                      ref={keyInputRef}
                      className={[
                        styles.keyInput,
                        !showKey && apiKey ? styles.secretMasked : "",
                      ].filter(Boolean).join(" ")}
                      placeholder={defaults.apiKeyPlaceholder}
                      value={apiKey}
                      onChange={(e) => {
                        setApiKey(e.target.value);
                        setError(null);
                        setKeyCharsError(null);
                        setState("idle");
                        if (e.target.value.length > 0 && setupStateRef.current.reachedStep === ProviderSetupStep.kindSelected) {
                          setupStateRef.current = {
                            ...setupStateRef.current,
                            kind: selectedKind,
                            reachedStep: ProviderSetupStep.apiKeyEntered,
                          };
                        }
                      }}
                      onPaste={() => {
                        setTimeout(handleConnect, 100);
                      }}
                      {...getApiKeyInputProps(
                        "provider-api-key",
                        showKey ? "visible" : "masked",
                      )}
                    />
                    <button
                      type="button"
                      className={styles.toggleVis}
                      onClick={() => setShowKey((v) => !v)}
                      aria-label={showKey ? t("hideKey") : t("showKey")}
                    >
                      {showKey ? <EyeOffIcon /> : <EyeIcon />}
                    </button>
                  </div>
                  <a
                    href={selectedAPIKeyHelpURL}
                    className={styles.helpLink}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    {t("getKeyAt", { provider: defaults.shortName })}
                  </a>
                </div>
                {keyCharsError && (
                  <div
                    className={styles.fieldError}
                    role="alert"
                    data-testid="provider-setup-key-chars-error"
                  >
                    {keyCharsError}
                  </div>
                )}

                {/* Region selector: Qwen / MiniMax / Kimi API keys are tied to a region */}
                {localizedEndpointOptions.length > 0 && (
                  <div className={styles.connectField}>
                    <div className={styles.sectionLabel}>{t("officialEndpoint")}</div>
                    <OfficialEndpointSelector
                      description={officialEndpointDescription}
                      options={localizedEndpointOptions}
                      value={selectedRegion}
                      onChange={(value) => {
                        setSelectedRegion(value);
                        setError(null);
                        setState("idle");
                      }}
                    />
                  </div>
                )}

                {/* Advanced: Base URL, not needed for aggregators or Qwen */}
                {!isAggregator && selectedRegionOptions.length === 0 && (
                  <div className={styles.advanced}>
                    <button
                      type="button"
                      className={styles.advancedToggle}
                      onClick={() => setAdvancedOpen((v) => !v)}
                    >
                      <svg
                        width="12"
                        height="12"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="currentColor"
                        strokeWidth="2"
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        style={{
                          transform: advancedOpen ? "rotate(90deg)" : "none",
                          transition: "transform 0.15s",
                        }}
                      >
                        <polyline points="9 18 15 12 9 6" />
                      </svg>
                      {t("advancedSettings")}
                    </button>
                    {advancedOpen && (
                      <div className={styles.advancedContent}>
                        <input
                          type="url"
                          className={styles.keyInput}
                          placeholder={defaults.defaultBaseURL}
                          value={baseURL}
                          onChange={(e) => setBaseURL(e.target.value)}
                        />
                      </div>
                    )}
                  </div>
                )}
                </>
                )}
                </>
                )}
              </div>
            )}
          </>
        )}
      </div>

      {/* CTA pinned to the bottom, disabled for custom, no selection or an empty key.
          The subscription flow keeps its primary action inside the connection panel, so a second
          disabled CTA down here would only make the flow look stuck. */}
      {!usesSubscriptionFlow && (
        <div className={styles.ctaArea}>
          <Button
            className={styles.ctaBtn}
            onClick={handleConnect}
            disabled={!canContinue}
          >
            {isWorking ? tc("loading") : t("connectAndSync")}
          </Button>
        </div>
      )}

      {showGrokSubscriptionDialog && grokSubscription.state === "available" && (
        <GrokSubscriptionAuthorizationDialog
          config={grokSubscription.config}
          onAuthorized={(credential) => { void completeGrokSubscriptionSetup(credential); }}
          onCancel={() => setShowGrokSubscriptionDialog(false)}
        />
      )}

      {showOpenAISubscriptionDialog && openAISubscription.state === "available" && (
        <OpenAISubscriptionAuthorizationDialog
          config={openAISubscription.config}
          onAuthorized={(credential) => { void completeOpenAISubscriptionSetup(credential); }}
          onCancel={() => setShowOpenAISubscriptionDialog(false)}
        />
      )}
    </div>
  );
}
