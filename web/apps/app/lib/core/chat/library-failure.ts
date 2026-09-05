import type { ChatMessage } from "@oriveo/shared";

/**
 * Maps library failure codes to localized copy, shared by all three paths.
 *
 * The agent path has its own catch in operations-library-send, while "specific document" and
 * server-side retrieval go through the generic catch in operations-send / operations-continue.
 * That generic catch only understands ProviderError, so for any library_* code it would show the
 * raw English text the server returned: a snake_case string such as `library_quota_exceeded`
 * reaching the user, and a recovery card without its dedicated CTAs (view plans, reconnect).
 * The rules and the copy need a single source of truth, or the three paths give three different
 * answers for the same code.
 */
export interface LibraryFailurePresentation {
  /** Failure card title. library_* codes do not fit the errors.* copy tree, so the title is localized at failure time and stored. */
  errorTitle: string;
  /** Fallback body text for codes that have no dedicated copy. */
  errorDetail: string;
  errorDetails?: Partial<Record<LibraryErrorCode | string, string>>;
  /**
   * messageKey -> localized copy.
   *
   * The server subdivides a single `code` with a `messageKey`; `library_source_error`, for
   * instance, collapses permission-style 403s such as Notion `restricted_resource` and Google
   * `domainPolicy` into `library.error.sourceForbidden`. Presentation maps on messageKey first;
   * an unknown one (a server that does not send it, or a case without copy yet) falls back to the
   * per-code copy, which keeps this backward compatible.
   */
  messageKeys?: Partial<Record<string, string>>;
}

/** Codes with dedicated copy. Everything else (disabled / not_found / source_error and so on) goes through `library_unavailable`. */
export type LibraryErrorCode =
  | "library_needs_reauth"
  | "library_quota_exceeded"
  | "library_rate_limited"
  | "library_research_step_limit"
  | "library_not_connected"
  | "library_unavailable";

/**
 * Decides whether an exception came from the library path.
 *
 * Structural rather than instanceof: the throwing side has two classes, `LibraryAPIError` (HTTP
 * layer) and `LibraryAgentError` (orchestration), and tests often mock the api module into a
 * different class of the same name, which instanceof would miss. ProviderError has no `code`
 * field (it uses `kind`), so it cannot be matched by this rule by accident.
 */
export function isLibraryFailure(error: unknown): boolean {
  if (!error || typeof error !== "object") return false;
  const code = (error as { code?: unknown }).code;
  return typeof code === "string" && code.startsWith("library_");
}

export function readLibraryErrorCode(error: unknown): string {
  if (!error || typeof error !== "object") return "library_source_error";
  const code = (error as { code?: unknown }).code;
  return typeof code === "string" && code.startsWith("library_")
    ? code
    : "library_source_error";
}

/** The messageKey the server sends to subdivide a code, or undefined when there is none. */
export function readLibraryErrorMessageKey(error: unknown): string | undefined {
  if (!error || typeof error !== "object") return undefined;
  const messageKey = (error as { messageKey?: unknown }).messageKey;
  return typeof messageKey === "string" && messageKey.trim() ? messageKey : undefined;
}

export function readLibraryErrorDetail(
  error: unknown,
  params: LibraryFailurePresentation,
): string {
  // messageKey wins over code: it is the finer case distinction within one code. An unknown
  // messageKey (a server that does not send it, or copy not written yet) falls back to the code.
  const messageKey = readLibraryErrorMessageKey(error);
  const mappedByMessageKey = messageKey ? params.messageKeys?.[messageKey] : undefined;
  if (mappedByMessageKey) return mappedByMessageKey;
  const code = readLibraryErrorCode(error);
  if (code === "library_needs_reauth") {
    return params.errorDetails?.library_needs_reauth ?? params.errorDetail;
  }
  if (code === "library_quota_exceeded") {
    return params.errorDetails?.library_quota_exceeded ?? params.errorDetail;
  }
  if (code === "library_rate_limited") {
    return params.errorDetails?.library_rate_limited ?? params.errorDetail;
  }
  // The server's per-research read and step ceiling was hit. The user can act on this by picking
  // fewer documents, whereas a generic "temporarily unavailable" would send them off to wait and
  // retry for nothing.
  if (code === "library_research_step_limit") {
    return (
      params.errorDetails?.library_research_step_limit ?? params.errorDetail
    );
  }
  // No library source has ever been connected (404). This differs from needs_reauth: there an
  // existing connection expired and needs reauthorizing, here nothing is connected at all, so the
  // copy has to point at connecting rather than reconnecting.
  if (code === "library_not_connected") {
    return params.errorDetails?.library_not_connected ?? params.errorDetail;
  }
  return params.errorDetails?.library_unavailable ?? params.errorDetail;
}

/**
 * Library failure patch for the generic catch: on a hit it replaces all three display fields of
 * the failure message.
 *
 * `errorKind` must carry the server's original error code -- the recovery card in MessageBubble
 * picks its dedicated CTA from it (needs_reauth -> open the library and reconnect,
 * quota_exceeded -> view plans). Writing the ProviderError kind there would leave only a generic
 * retry.
 */
export function libraryFailurePatch(
  error: unknown,
  presentation: LibraryFailurePresentation | undefined,
): Pick<ChatMessage, "errorTitle" | "errorDetail" | "errorKind"> | null {
  if (!presentation || !isLibraryFailure(error)) return null;
  return {
    errorTitle: presentation.errorTitle,
    errorDetail: readLibraryErrorDetail(error, presentation),
    errorKind: readLibraryErrorCode(error),
  };
}
