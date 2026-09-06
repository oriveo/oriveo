import { describe, expect, it } from "vitest";
import {
  buildProviderSentryContext,
  createProviderSentryError,
  normalizeChatFailure,
  shouldReportProviderError,
} from "../error-reporting";
import type { ErrorWithProviderDetail } from "../../../sentry/provider-error-detail";

describe("createProviderSentryError", () => {
  it("attaches the whitelisted provider detail for diagnosis", () => {
    const err = createProviderSentryError({
      kind: "upstream",
      title: "Provider Error",
      message: "The AI provider is experiencing issues.",
      detail: "Upstream HTTP 500: bad gateway",
    }) as ErrorWithProviderDetail;
    expect(err.name).toBe("ProviderError");
    expect(err.message).toContain("upstream");
    expect(err.providerErrorDetail).toBe("Upstream HTTP 500: bad gateway");
  });

  it("does not attach detail when absent", () => {
    const err = createProviderSentryError({
      kind: "network",
      title: "Network Error",
      message: "Unable to connect.",
    }) as ErrorWithProviderDetail;
    expect("providerErrorDetail" in err).toBe(false);
  });
});

describe("shouldReportProviderError", () => {
  it("drops every upstream response by ownership, independent of error kind", () => {
    for (const kind of ["upstream", "rateLimited", "unavailable", "emptyResponse"] as const) {
      expect(shouldReportProviderError({
        kind,
        title: "",
        message: "upstream said no",
        source: "provider",
      })).toBe(false);
    }
  });

  it("drops user-config errors", () => {
    expect(shouldReportProviderError({ kind: "invalidKey", title: "", message: "" })).toBe(false);
  });

  it("drops network-layer failures by kind (Safari 'Load failed')", () => {
    expect(shouldReportProviderError({ kind: "network", title: "", message: "Load failed" })).toBe(false);
  });

  it("drops network-layer failures by kind (Chrome 'Failed to fetch')", () => {
    expect(shouldReportProviderError({ kind: "network", title: "", message: "Failed to fetch" })).toBe(false);
  });

  it("drops network 'Load failed' with a host suffix, generalizing by kind so variants are not missed", () => {
    expect(
      shouldReportProviderError({ kind: "network", title: "", message: "Load failed (api.localhost)" }),
    ).toBe(false);
  });

  it("drops mid-stream reset now reclassified as network (was mislabeled upstream)", () => {
    expect(shouldReportProviderError({ kind: "network", title: "", message: "terminated" })).toBe(false);
  });

  it("keeps an Oriveo-owned unexpected failure with the same semantic kind", () => {
    expect(
      shouldReportProviderError({
        kind: "upstream",
        title: "Provider Error",
        message: "The AI provider is experiencing issues.",
        source: "oriveo",
      }),
    ).toBe(true);
  });

  // 429 is an expected path regardless of reporter.
  it("drops rate limiting regardless of who reported it", () => {
    for (const source of ["oriveo", "provider", "unknown", undefined] as const) {
      expect(shouldReportProviderError({
        kind: "rateLimited",
        title: "",
        message: "429 | Provider returned error",
        ...(source ? { source } : {}),
      })).toBe(false);
    }
  });

  it("drops user-authored custom request field rejections (fail-closed is by design)", () => {
    expect(shouldReportProviderError({ kind: "customRequestFieldsRejected", source: "oriveo" })).toBe(false);
  });

  it("splits subscription failures by ownership: account state is noise, our config is a defect", () => {
    for (const kind of [
      "grokSubscriptionIneligible",
      "grokSubscriptionExpired",
      "grokSubscriptionQuotaExhausted",
      "openAISubscriptionIneligible",
      "openAISubscriptionExpired",
      "openAISubscriptionQuotaExhausted",
    ]) {
      expect(shouldReportProviderError({ kind, source: "oriveo" })).toBe(false);
    }
    // 426 or a missing local recipe means our own configuration is broken, so it must still come through
    expect(shouldReportProviderError({ kind: "grokSubscriptionUnavailable", source: "oriveo" })).toBe(true);
    expect(shouldReportProviderError({ kind: "openAISubscriptionUnavailable", source: "oriveo" })).toBe(true);
  });

  it("drops a bare fetch transport failure that carries no provider kind at all", () => {
    const failedToFetch = new TypeError("Failed to fetch (api.localhost)");
    expect(shouldReportProviderError(failedToFetch)).toBe(false);
    const aborted = new Error("aborted");
    aborted.name = "AbortError";
    expect(shouldReportProviderError(aborted)).toBe(false);
  });

  it("still reports a genuine client-side TypeError", () => {
    expect(shouldReportProviderError(new TypeError("t.map is not a function"))).toBe(true);
  });
});

describe("normalizeChatFailure", () => {
  it("gives a bare fetch failure the network semantics the failure card needs", () => {
    // Without normalization mapErrorKindKey(undefined) falls back to upstream, so "your network is
    // down" is shown as "the AI provider is having trouble, try again later" and the user just
    // keeps retrying.
    const normalized = normalizeChatFailure(new TypeError("Failed to fetch (api.localhost)"));
    expect(normalized.kind).toBe("network");
    expect(normalized.source).toBe("network");
    // The engine's original text stays in detail as a fallback for the technical details view
    expect(normalized.detail).toBe("Failed to fetch (api.localhost)");
  });

  it("never reclassifies an error that already carries a kind", () => {
    const provider = { kind: "rateLimited", title: "", message: "429", source: "oriveo" } as const;
    expect(normalizeChatFailure(provider)).toBe(provider);
    // A genuine defect passes through unchanged: it has to stay visible as a defect
    const bug = new TypeError("t.map is not a function");
    expect(normalizeChatFailure(bug)).toBe(bug as unknown as ReturnType<typeof normalizeChatFailure>);
  });
});

describe("buildProviderSentryContext", () => {
  it("separates issues by provider and error kind and carries whitelisted detail directly", () => {
    expect(buildProviderSentryContext("relay", {
      kind: "upstream",
      title: "Provider Error",
      message: "failed",
      detail: "Upstream HTTP 502: unavailable",
    })).toEqual({
      fingerprint: ["provider-error", "relay", "upstream"],
      extra: { providerErrorDetail: "Upstream HTTP 502: unavailable" },
    });
  });
});
