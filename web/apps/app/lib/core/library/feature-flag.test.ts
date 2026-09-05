import { afterEach, describe, expect, it, vi } from "vitest";
import { isLibraryFeatureEnabled } from "./feature-flag";
import {
  DEFAULT_LIBRARY_RUNTIME_CONFIG,
  isLibraryEnabledByServer,
  resolveAvailableLibraryProviders,
} from "./types";

const getLibraryRuntimeConfig = vi.hoisted(() => vi.fn());

vi.mock("../metadata/metadata-client", () => ({ getLibraryRuntimeConfig }));

describe("isLibraryFeatureEnabled", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    getLibraryRuntimeConfig.mockReset();
  });

  // The build flag is opt-in: a build with no document source wired up must not draw an entry point
  // that leads to a request which cannot succeed.
  it("keeps Library off when the build flag is missing", () => {
    vi.stubEnv("NEXT_PUBLIC_LIBRARY_ENABLED", undefined);
    getLibraryRuntimeConfig.mockReturnValue(DEFAULT_LIBRARY_RUNTIME_CONFIG);

    expect(isLibraryFeatureEnabled()).toBe(false);
  });

  it("enables Library when the build flag is explicitly true", () => {
    vi.stubEnv("NEXT_PUBLIC_LIBRARY_ENABLED", "true");
    getLibraryRuntimeConfig.mockReturnValue(DEFAULT_LIBRARY_RUNTIME_CONFIG);

    expect(isLibraryFeatureEnabled()).toBe(true);
  });

  it("keeps Library off when the build flag is explicitly false", () => {
    vi.stubEnv("NEXT_PUBLIC_LIBRARY_ENABLED", "false");
    getLibraryRuntimeConfig.mockReturnValue(DEFAULT_LIBRARY_RUNTIME_CONFIG);

    expect(isLibraryFeatureEnabled()).toBe(false);
  });

  // The catalog is authoritative for the other half: when it reports the source as unavailable, no
  // entry point is drawn even in a build that has one wired up.
  it("respects the catalog-authoritative kill switch", () => {
    vi.stubEnv("NEXT_PUBLIC_LIBRARY_ENABLED", "true");
    getLibraryRuntimeConfig.mockReturnValue({
      ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
      enabled: false,
    });

    expect(isLibraryFeatureEnabled()).toBe(false);
  });
});

describe("library server authority helpers", () => {
  // An older server that does not send enabled is still treated as available, otherwise the feature
  // would vanish during a rollout. The source list only falls back to Notion though: in production v3
  // does not send availableProviders, and falling back to the whole list would draw a Google card the
  // server has not configured, which answers 503 when the user taps it.
  it("falls back to enabled with only Notion on an older server", () => {
    const legacy = { ...DEFAULT_LIBRARY_RUNTIME_CONFIG };
    delete legacy.enabled;
    delete legacy.availableProviders;

    expect(isLibraryEnabledByServer(legacy)).toBe(true);
    expect(resolveAvailableLibraryProviders(legacy)).toEqual(["notion"]);
  });

  // Regression for "Google Drive looks tappable but does nothing": with only Notion enabled server-side, no Google connect card is rendered.
  it("only exposes providers the server reports as connectable", () => {
    expect(
      resolveAvailableLibraryProviders({
        ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
        availableProviders: ["notion"],
      }),
    ).toEqual(["notion"]);

    expect(
      resolveAvailableLibraryProviders({
        ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
        availableProviders: [],
      }),
    ).toEqual([]);
  });

  it("ignores unknown provider identifiers", () => {
    expect(
      resolveAvailableLibraryProviders({
        ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
        availableProviders: ["notion", "dropbox"],
      }),
    ).toEqual(["notion"]);
  });
});
