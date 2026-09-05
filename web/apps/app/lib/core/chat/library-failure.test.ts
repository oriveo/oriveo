import { describe, expect, it } from "vitest";
import {
  isLibraryFailure,
  libraryFailurePatch,
  readLibraryErrorCode,
  readLibraryErrorDetail,
  readLibraryErrorMessageKey,
  type LibraryFailurePresentation,
} from "./library-failure";

function presentation(
  overrides: Partial<LibraryFailurePresentation> = {},
): LibraryFailurePresentation {
  return {
    errorTitle: "Library research failed",
    errorDetail: "Something went wrong. Please try again.",
    errorDetails: {
      library_needs_reauth: "Reconnect required.",
      library_not_connected: "Connect a Library source first.",
    },
    messageKeys: {
      "library.error.sourceForbidden": "Access denied by the source policy.",
    },
    ...overrides,
  };
}

describe("readLibraryErrorDetail", () => {
  it("picks the copy for the error code and falls back to the generic body for an unknown code", () => {
    expect(
      readLibraryErrorDetail(
        { code: "library_needs_reauth" },
        presentation(),
      ),
    ).toBe("Reconnect required.");
    expect(
      readLibraryErrorDetail({ code: "library_source_error" }, presentation()),
    ).toBe("Something went wrong. Please try again.");
  });

  // A code that has never been connected to any source gets different copy from needs_reauth.
  it("library_not_connected uses its own copy and is not conflated with needs_reauth", () => {
    expect(
      readLibraryErrorDetail(
        { code: "library_not_connected" },
        presentation(),
      ),
    ).toBe("Connect a Library source first.");
  });

  // messageKey takes precedence over code; an unknown messageKey falls back to the copy for the code.
  it("messageKey takes precedence over the copy selected by code", () => {
    expect(
      readLibraryErrorDetail(
        { code: "library_source_error", messageKey: "library.error.sourceForbidden" },
        presentation(),
      ),
    ).toBe("Access denied by the source policy.");
  });

  it("an unknown messageKey falls back to the copy selected by code", () => {
    expect(
      readLibraryErrorDetail(
        { code: "library_source_error", messageKey: "library.error.someFutureReason" },
        presentation(),
      ),
    ).toBe("Something went wrong. Please try again.");
  });

  it("falls back safely when the presentation carries no messageKeys", () => {
    const withoutMessageKeys = presentation();
    delete withoutMessageKeys.messageKeys;
    expect(
      readLibraryErrorDetail(
        { code: "library_source_error", messageKey: "library.error.sourceForbidden" },
        withoutMessageKeys,
      ),
    ).toBe("Something went wrong. Please try again.");
  });
});

describe("readLibraryErrorMessageKey", () => {
  it("returns undefined for a non-object, a missing messageKey or an empty string", () => {
    expect(readLibraryErrorMessageKey(null)).toBeUndefined();
    expect(readLibraryErrorMessageKey("oops")).toBeUndefined();
    expect(readLibraryErrorMessageKey({ code: "library_source_error" })).toBeUndefined();
    expect(readLibraryErrorMessageKey({ messageKey: "" })).toBeUndefined();
  });

  it("returns a valid string unchanged", () => {
    expect(
      readLibraryErrorMessageKey({ messageKey: "library.error.sourceForbidden" }),
    ).toBe("library.error.sourceForbidden");
  });
});

describe("readLibraryErrorCode / isLibraryFailure", () => {
  it("anything without the library_ prefix maps to library_source_error", () => {
    expect(readLibraryErrorCode({ code: "provider_rate_limited" })).toBe(
      "library_source_error",
    );
    expect(readLibraryErrorCode(null)).toBe("library_source_error");
  });

  it("isLibraryFailure decides structurally and does not rely on instanceof", () => {
    expect(isLibraryFailure({ code: "library_not_connected" })).toBe(true);
    expect(isLibraryFailure({ code: "provider_error" })).toBe(false);
    expect(isLibraryFailure(new Error("plain"))).toBe(false);
  });
});

describe("libraryFailurePatch", () => {
  it("replaces all three display fields on a library failure while errorKind keeps the server code", () => {
    const patch = libraryFailurePatch(
      { code: "library_not_connected" },
      presentation(),
    );
    expect(patch).toEqual({
      errorTitle: "Library research failed",
      errorDetail: "Connect a Library source first.",
      errorKind: "library_not_connected",
    });
  });

  it("returns null for a non-library failure or when there is no presentation", () => {
    expect(libraryFailurePatch({ code: "provider_error" }, presentation())).toBeNull();
    expect(libraryFailurePatch({ code: "library_not_connected" }, undefined)).toBeNull();
  });
});
