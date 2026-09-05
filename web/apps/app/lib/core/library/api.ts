/**
 * Client for the document source that backs Library research.
 *
 * A source is an external service holding the user's documents, reached through a connector this
 * build does not ship. Until one is wired up `isLibraryBuildEnabled()` keeps every Library surface
 * off, so these functions are the integration point rather than a path the app takes. The error
 * type and its classifiers are not part of that gap: every caller in the agent loop and the direct
 * context path decides what to do from them, so they carry the full contract a connector reports.
 */

import type { LibraryQuota, LibraryResearchResult, LibraryToolResult } from './types';

export class LibraryAPIError extends Error {
  constructor(
    message: string,
    public readonly status: number,
    public readonly code?: string,
    public readonly retryAfter?: number,
    public readonly quota?: LibraryQuota,
    /**
     * Sent when a source distinguishes several situations under one code, for example when
     * permission-style 403s from different sources all arrive as `library_source_error`. The
     * presentation layer prefers it and falls back to the copy for the code itself, so a source
     * that does not send it behaves as before.
     */
    public readonly messageKey?: string,
  ) {
    super(message);
    this.name = 'LibraryAPIError';
  }
}

/**
 * Whatever the tool returned, plus the quota the source reported alongside it. The result shape is
 * per tool, so callers narrow it themselves.
 */
export interface LibraryToolResponse {
  result: LibraryToolResult;
  quota?: LibraryQuota;
}

const NO_SOURCE = 'No document source is configured.';

/**
 * A retryable rate limit, which an exhausted monthly quota is not: retrying that one only burns
 * time, so it is excluded even though both arrive as 429.
 */
export function isLibraryRateLimitError(error: unknown): error is LibraryAPIError {
  return (
    error instanceof LibraryAPIError
    && error.code !== 'library_quota_exceeded'
    && (error.status === 429 || error.code === 'library_rate_limited')
  );
}

export function isLibraryNotFoundError(error: unknown): error is LibraryAPIError {
  return error instanceof LibraryAPIError && error.code === 'library_not_found';
}

export async function executeLibraryResearch(
  ..._args: unknown[]
): Promise<{ result: LibraryResearchResult; quota?: LibraryQuota }> {
  throw new LibraryAPIError(NO_SOURCE, 501);
}

export async function executeLibraryTool(..._args: unknown[]): Promise<LibraryToolResponse> {
  throw new LibraryAPIError(NO_SOURCE, 501);
}

export async function searchLibrary(..._args: unknown[]): Promise<{ items: never[] }> {
  return { items: [] };
}
