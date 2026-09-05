import { describe, expect, it } from "vitest";
import {
  PHASE_DEVELOPMENT_SERVER,
  PHASE_PRODUCTION_BUILD,
  PHASE_PRODUCTION_SERVER,
} from "next/constants";
import { createOriveoNextConfig } from "./next.config";

describe("next.config distDir isolation", () => {
  it("uses a dedicated distDir for the development server", () => {
    expect(createOriveoNextConfig(PHASE_DEVELOPMENT_SERVER).distDir).toBe(
      ".next-dev",
    );
  });

  it("shares the default distDir between production build and start", () => {
    expect(createOriveoNextConfig(PHASE_PRODUCTION_BUILD).distDir).toBe(
      ".next",
    );
    expect(createOriveoNextConfig(PHASE_PRODUCTION_SERVER).distDir).toBe(
      ".next",
    );
  });
});

describe("next.config popup headers", () => {
  it("lets an authorization popup keep talking to the window that opened it", async () => {
    const config = createOriveoNextConfig(PHASE_PRODUCTION_SERVER);
    const routes = await config.headers?.();
    const appRoute = routes?.find((route) => route.source === "/:path*");
    const coopHeader = appRoute?.headers.find(
      (header) => header.key === "Cross-Origin-Opener-Policy",
    );

    expect(coopHeader?.value).toBe("same-origin-allow-popups");
  });
});

describe("next.config mobile development chrome", () => {
  it("disables the Next.js development indicator so it does not cover the mobile tab bar", () => {
    expect(createOriveoNextConfig(PHASE_DEVELOPMENT_SERVER).devIndicators).toBe(false);
  });

  it("allows 127.0.0.1 HMR only for the development server", () => {
    expect(createOriveoNextConfig(PHASE_DEVELOPMENT_SERVER).allowedDevOrigins).toContain("127.0.0.1");
    expect(createOriveoNextConfig(PHASE_PRODUCTION_SERVER).allowedDevOrigins).toBeUndefined();
  });
});
