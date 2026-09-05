import { describe, expect, it } from "vitest";
import type { Event, EventHint } from "@sentry/nextjs";
import {
  PROVIDER_ERROR_DETAIL_MAX,
  attachProviderErrorDetail,
  attachProviderErrorSource,
  isProviderResponseErrorHint,
  liftProviderErrorDetail,
  type ErrorWithProviderDetail,
} from "../provider-error-detail";

describe("attachProviderErrorDetail", () => {
  it("attaches the detail onto the error", () => {
    const err = new Error("Provider upstream: ...") as ErrorWithProviderDetail;
    attachProviderErrorDetail(err, "Upstream HTTP 500: rate limit reached");
    expect(err.providerErrorDetail).toBe("Upstream HTTP 500: rate limit reached");
  });

  it("truncates an over-long detail", () => {
    const err = new Error("x") as ErrorWithProviderDetail;
    attachProviderErrorDetail(err, "z".repeat(PROVIDER_ERROR_DETAIL_MAX + 50));
    expect(err.providerErrorDetail?.length).toBe(PROVIDER_ERROR_DETAIL_MAX);
  });

  it("does not attach when detail is missing", () => {
    const err = new Error("x") as ErrorWithProviderDetail;
    attachProviderErrorDetail(err, undefined);
    expect("providerErrorDetail" in err).toBe(false);
  });
});

describe("liftProviderErrorDetail", () => {
  function hintWith(detail: string | undefined): EventHint {
    const err = new Error("wrapped") as ErrorWithProviderDetail;
    if (detail !== undefined) err.providerErrorDetail = detail;
    return { originalException: err } as EventHint;
  }

  it("lifts the attached detail into event.extra", () => {
    const event = liftProviderErrorDetail({} as Event, hintWith("Upstream HTTP 500: boom"));
    expect(event.extra?.providerErrorDetail).toBe("Upstream HTTP 500: boom");
  });

  it("preserves existing extra fields", () => {
    const event = liftProviderErrorDetail({ extra: { foo: 1 } } as unknown as Event, hintWith("d"));
    expect(event.extra).toEqual({ foo: 1, providerErrorDetail: "d" });
  });

  it("leaves the event untouched when there is no attached detail", () => {
    const event = liftProviderErrorDetail({} as Event, hintWith(undefined));
    expect(event.extra?.providerErrorDetail).toBeUndefined();
  });

  it("leaves the event untouched when there is no hint", () => {
    const event = liftProviderErrorDetail({ extra: { foo: 1 } } as unknown as Event, undefined);
    expect(event.extra).toEqual({ foo: 1 });
  });
});

describe("provider response Sentry boundary", () => {
  it("drops a wrapped provider response by its attached source", () => {
    const err = new Error("wrapped") as ErrorWithProviderDetail;
    attachProviderErrorSource(err, "provider");
    expect(isProviderResponseErrorHint({ originalException: err } as EventHint)).toBe(true);
  });

  it("drops a directly captured ProviderErrorObject-compatible value", () => {
    const err = Object.assign(new Error("upstream"), { source: "provider" as const });
    expect(isProviderResponseErrorHint({ originalException: err } as EventHint)).toBe(true);
  });

  it("keeps Oriveo-owned failures", () => {
    const err = Object.assign(new Error("internal"), { source: "oriveo" as const });
    expect(isProviderResponseErrorHint({ originalException: err } as EventHint)).toBe(false);
  });
});
