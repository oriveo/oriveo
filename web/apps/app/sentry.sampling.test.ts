import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const appRoot = resolve(__dirname);

function readConfig(path: string) {
  return readFileSync(resolve(appRoot, path), "utf8");
}

describe("Sentry sampling policy", () => {
  it("keeps browser performance and replay sampling conservative in production", () => {
    const config = readConfig("instrumentation-client.ts");

    expect(config).toContain("tracesSampleRate: 0.1");
    expect(config).toContain("replaysOnErrorSampleRate: 1.0");
    expect(config).toContain("replaysSessionSampleRate: 0.01");
    expect(config).toContain("slowClickIgnoreSelectors");
    expect(config).toContain(
      '[data-sentry-ignore-slow-click="sync-state-reset"]',
    );
  });

  it("uses conservative server and edge performance sampling", () => {
    expect(readConfig("sentry.server.config.ts")).toContain(
      "tracesSampleRate: 0.1",
    );
    expect(readConfig("sentry.edge.config.ts")).toContain(
      "tracesSampleRate: 0.1",
    );
  });
});
