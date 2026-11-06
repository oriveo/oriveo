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

const UNHANDLED_REJECTION = { type: "auto.browser.global_handlers.onunhandledrejection", handled: false };
/** Mechanism of an error we captured ourselves with `Sentry.captureException`. */
const HANDLED_CAPTURE = { type: "generic", handled: true };

/** Shape of a raw browser payload with a stack. */
function buildRejectionEvent(
  entry: { type: string; value: string; frames?: Array<{ filename: string; function?: string }> },
  mechanism: { type: string; handled: boolean } = UNHANDLED_REJECTION,
): Event {
  return {
    exception: {
      values: [{
        type: entry.type,
        value: entry.value,
        mechanism,
        ...(entry.frames ? { stacktrace: { frames: entry.frames } } : {}),
      }],
    },
  } as unknown as Event;
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

  it("drops iOS Safari userscript-manager injection errors", () => {
    expect(isIgnorableBrowserNoiseError(buildEvent([{
      type: "TypeError",
      value: "undefined is not an object (evaluating 'window['3f2a9c1e-7b4d-4e8a-9c2f-1d5e6a7b8c9d']['gm_menus']')",
    }]))).toBe(true);
    expect(isIgnorableBrowserNoiseError(buildEvent([{
      type: "TypeError",
      value: "null is not an object (evaluating 'window[\"3F2A9C1E-7B4D-4E8A-9C2F-1D5E6A7B8C9D\"].GM_info')",
    }]))).toBe(true);
    expect(isIgnorableBrowserNoiseError(buildEvent([{ type: "TypeError", value: "Cannot read properties of undefined (reading 'gm_menus')" }]))).toBe(true);
  });

  it("KEEPS look-alike own errors (generic Safari TypeError / non-UUID window access)", () => {
    expect(isIgnorableBrowserNoiseError(buildEvent([
      { type: "TypeError", value: "undefined is not an object (evaluating 'window['__ORIVEO_STATE__']['menus']')" },
    ]))).toBe(false);
    expect(isIgnorableBrowserNoiseError(buildEvent([
      { type: "TypeError", value: "undefined is not an object (evaluating 'state.menus')" },
    ]))).toBe(false);
    expect(isIgnorableBrowserNoiseError(buildEvent([
      { type: "Error", value: "conversation 3f2a9c1e-7b4d-4e8a-9c2f-1d5e6a7b8c9d menus missing" },
    ]))).toBe(false);
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

describe("reCAPTCHA script errors", () => {
  const RECAPTCHA_JS = "app:///recaptcha/releases/bSuJ2xBC8cFy7pM4Z3Hu9boH/recaptcha__fa.js";
  const OWN_CHUNK = "app:///_next/static/chunks/0b1c8e2f4d6a9c3e.js";
  const SET_TIMEOUT_WRAPPER = { type: "auto.browser.browserapierrors.customSetTimeout", handled: false };

  it("drops the promise timeout thrown inside the script", () => {
    const event = buildRejectionEvent({
      type: "Error",
      value: "reCAPTCHA Timeout (b)",
      frames: [{ filename: RECAPTCHA_JS }],
    });
    expect(isIgnorableBrowserNoiseError(event)).toBe(true);
  });

  it("drops the timer crash under Sentry's setTimeout wrapper", () => {
    const event = buildRejectionEvent({
      type: "TypeError",
      value: "Cannot read properties of undefined (reading 'nc')",
      frames: [
        { filename: OWN_CHUNK, function: "l" },
        { filename: "app:///recaptcha/releases/bSuJ2xBC8cFy7pM4Z3Hu9boH/recaptcha__en.js", function: "Wm.<anonymous>" },
        { filename: "app:///recaptcha/releases/bSuJ2xBC8cFy7pM4Z3Hu9boH/recaptcha__en.js", function: "Wm.P.Wm.iF.U.Un" },
      ],
    }, SET_TIMEOUT_WRAPPER);
    expect(isIgnorableBrowserNoiseError(event)).toBe(true);
  });

  it("keeps a crash whose top frame is our own code", () => {
    const event = buildRejectionEvent({
      type: "TypeError",
      value: "Cannot read properties of undefined (reading 'nc')",
      frames: [{ filename: RECAPTCHA_JS }, { filename: OWN_CHUNK, function: "onToken" }],
    });
    expect(isIgnorableBrowserNoiseError(event)).toBe(false);
  });

  it("keeps the same frame when we captured the error ourselves", () => {
    const event = buildRejectionEvent(
      { type: "Error", value: "reCAPTCHA Timeout (b)", frames: [{ filename: RECAPTCHA_JS }] },
      HANDLED_CAPTURE,
    );
    expect(isIgnorableBrowserNoiseError(event)).toBe(false);
  });

  it("keeps the same text without a stack", () => {
    const event = buildRejectionEvent({ type: "Error", value: "reCAPTCHA Timeout (b)" });
    expect(isIgnorableBrowserNoiseError(event)).toBe(false);
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
