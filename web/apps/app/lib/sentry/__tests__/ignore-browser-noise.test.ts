import { describe, expect, it } from "vitest";
import type { Event } from "@sentry/nextjs";
import {
  CHUNK_RELOAD_STORAGE_KEY,
  consumeChunkReloadAttempt,
  isChunkLoadError,
  isIgnorableBrowserNoiseError,
} from "../ignore-browser-noise";

function buildEvent(values: Array<{ type?: string; value?: string }>): Event {
  return { exception: { values } } as unknown as Event;
}

describe("isChunkLoadError", () => {
  it("matches a ChunkLoadError by name", () => {
    const err = Object.assign(new Error("Loading chunk 9886 failed."), { name: "ChunkLoadError" });
    expect(isChunkLoadError(err)).toBe(true);
  });

  it("matches webpack 'Loading chunk N failed' message", () => {
    expect(isChunkLoadError(new Error("Loading chunk 42 failed.\n(error: https://app/_next/static/chunks/42.js)"))).toBe(true);
  });

  it("matches ESM 'Failed to fetch dynamically imported module'", () => {
    expect(isChunkLoadError(new Error("Failed to fetch dynamically imported module: https://app/_next/x.js"))).toBe(true);
  });

  it("matches 'error loading dynamically imported module'", () => {
    expect(isChunkLoadError(new Error("error loading dynamically imported module"))).toBe(true);
  });

  it("matches Safari 'Importing a module script failed'", () => {
    expect(isChunkLoadError(new Error("Importing a module script failed."))).toBe(true);
  });

  it("does not match a normal application error", () => {
    expect(isChunkLoadError(new TypeError("Cannot read properties of undefined (reading 'x')"))).toBe(false);
  });

  it("does not match non-error inputs", () => {
    expect(isChunkLoadError("Loading chunk failed")).toBe(false);
    expect(isChunkLoadError(null)).toBe(false);
    expect(isChunkLoadError(undefined)).toBe(false);
  });
});

describe("isIgnorableBrowserNoiseError", () => {
  it("drops chunk load errors (self-healed by reload)", () => {
    expect(isIgnorableBrowserNoiseError(buildEvent([{ type: "ChunkLoadError", value: "Loading chunk 9886 failed." }]))).toBe(true);
  });

  it("drops IndexedDB 'server lost' environment errors", () => {
    expect(isIgnorableBrowserNoiseError(buildEvent([
      { type: "UnknownError", value: "Connection to Indexed Database server lost. Refresh the page to try again" },
    ]))).toBe(true);
  });

  it("drops IndexedDB 'connection is closing' errors", () => {
    expect(isIgnorableBrowserNoiseError(buildEvent([
      { type: "InvalidStateError", value: "Failed to execute 'transaction' on 'IDBDatabase': The database connection is closing." },
    ]))).toBe(true);
  });

  it("drops opaque cross-origin 'Script error.'", () => {
    expect(isIgnorableBrowserNoiseError(buildEvent([{ type: "Error", value: "Script error." }]))).toBe(true);
  });

  it("KEEPS provider upstream/network errors (our infra signal)", () => {
    expect(isIgnorableBrowserNoiseError(buildEvent([
      { type: "ProviderError", value: "Provider upstream: The AI provider is experiencing issues." },
    ]))).toBe(false);
    expect(isIgnorableBrowserNoiseError(buildEvent([
      { type: "ProviderError", value: "Provider network: Failed to fetch" },
    ]))).toBe(false);
  });

  it("KEEPS 'Store not initialized' (real signal once chunk reload no longer recovers)", () => {
    expect(isIgnorableBrowserNoiseError(buildEvent([{ type: "Error", value: "Store not initialized" }]))).toBe(false);
  });

  it("KEEPS generic application TypeErrors", () => {
    expect(isIgnorableBrowserNoiseError(buildEvent([
      { type: "TypeError", value: "undefined is not an object (evaluating 'e.hasCustomTitle')" },
    ]))).toBe(false);
  });

  it("handles events with no exception", () => {
    expect(isIgnorableBrowserNoiseError({} as Event)).toBe(false);
  });
});

describe("consumeChunkReloadAttempt", () => {
  function memoryStorage(): Pick<Storage, "getItem" | "setItem"> {
    const m = new Map<string, string>();
    return {
      getItem: (k) => m.get(k) ?? null,
      setItem: (k, v) => { m.set(k, v); },
    };
  }

  it("allows the first reload and marks the guard", () => {
    const storage = memoryStorage();
    expect(consumeChunkReloadAttempt(storage)).toBe(true);
    expect(storage.getItem(CHUNK_RELOAD_STORAGE_KEY)).toBe("1");
  });

  it("blocks a second reload within the same session (no loop)", () => {
    const storage = memoryStorage();
    consumeChunkReloadAttempt(storage);
    expect(consumeChunkReloadAttempt(storage)).toBe(false);
  });
});
