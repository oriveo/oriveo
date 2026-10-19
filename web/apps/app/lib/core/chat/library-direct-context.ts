import type { Citation } from "@oriveo/shared";
import type { LibraryEntry } from "@oriveo/core/context/assemble";
import { graphemeCount, takeGraphemes } from "../../utils/grapheme-utils";
import {
  isLibraryNotFoundError,
  isLibraryRateLimitError,
  type LibraryAPIError,
} from "../library/api";
import {
  resolveDirectContextCharBudget,
  resolveDirectMaxDocuments,
} from "../library/types";
import type {
  LibraryConfirmationChoice,
  LibraryConfirmationRequest,
  LibraryDocumentRef,
  LibraryQuota,
  LibraryReadArgs,
  LibraryReadResult,
  LibraryReadSection,
  LibraryResearchStep,
  LibraryRuntimeConfig,
} from "../library/types";
import {
  applyServerRedactedLibraryRead,
  buildLibraryReadConfirmation,
  isTrustedLibraryURL,
  LibraryAgentError,
  LibraryResearchCancelledError,
  resolveLibraryCitationURL,
} from "./library-agent-loop";

/**
 * Hard cap on read calls for a single "selected documents" research pass; the server CHECK uses
 * the same 64 (see migration 0071).
 *
 * The budget is shared across every selected document, not 64 per document: counting per document
 * lets 12 selected files issue over 700 reads, blow through the server cap, and fail the whole
 * message with an error that has no copy behind it.
 */
const MAX_DIRECT_READ_CALLS = 64;

export interface LibraryDirectContextResult {
  /**
   * Library items that go into [D], one per document; the n-th citation = n (one-to-one with citations).
   * Empty array = retrieval / reading happened but produced no evidence at all; the assembler emits libraryEmptyEntry accordingly --
   * if the model is not told "there is no evidence", it will invent an answer from empty evidence.
   */
  entries: LibraryEntry[];
  citations: Citation[];
}

export interface ReadLibraryDirectContextOptions {
  documents: LibraryDocumentRef[];
  config: LibraryRuntimeConfig;
  /** Context window of the selected model, which sets the body injection budget; treated as a conservative window when unknown. */
  modelContextLength?: number;
  signal: AbortSignal;
  executeRead: (
    args: LibraryReadArgs,
    toolCallId: string,
    signal: AbortSignal,
  ) => Promise<{ result: LibraryReadResult; quota?: LibraryQuota }>;
  requestConfirmation: (
    request: LibraryConfirmationRequest,
  ) => Promise<LibraryConfirmationChoice>;
  onQuota?: (quota: LibraryQuota) => void;
  /**
   * Per-document read progress. Research mode has a step list; without one the selected-documents
   * path offers only a typing indicator, and a user who picked several long documents has no idea
   * what they are waiting for.
   */
  onSteps?: (steps: LibraryResearchStep[]) => void;
}

export async function readLibraryDirectContext(
  options: ReadLibraryDirectContextOptions,
): Promise<LibraryDirectContextResult> {
  // The picker already keeps the selection under the limit; clamping again here stops an
  // oversized selection carried in by a retry of an older conversation from bypassing the budget,
  // where the extra documents would only squeeze out the body of the earlier ones.
  const documents = dedupeLibraryDocumentRefs(options.documents)
    .slice(0, resolveDirectMaxDocuments(options.config));
  const reads: LibraryReadResult[] = [];
  // Source documents aligned one-to-one with reads: once a document is skipped (404) the read
  // index stops matching the documents index, and taking the citation identity from
  // documents[index] would attach evidence to the wrong document.
  const readDocuments: LibraryDocumentRef[] = [];
  // Ask once when several documents in one send hit sensitive content, then apply that choice to
  // the remaining hits. Scoped to this send only: sensitive content varies per message, so
  // remembering it across messages would disable the gate.
  let sensitiveChoice: LibraryConfirmationChoice | undefined;
  // The per-document body budget for the envelope is the whole budget (with several documents it
  // is smaller still); anything read beyond it by paging further is certain to be dropped whole in
  // clipSections, wasting a round trip and a unit of server read quota.
  const charBudget = resolveDirectContextCharBudget(
    options.config,
    options.modelContextLength,
  );
  // The step list is shared with research mode: one step per document, labelled with the document title rather than a bare docId
  const steps: LibraryResearchStep[] = documents.map((document, index) => ({
    id: `direct:${document.source}:${document.docId}`,
    tool: "library_read",
    label: document.title,
    status: "pending",
    step: index + 1,
  }));
  // Every report sends a deep copy: the caller stores these steps on the message, and a shared
  // object would make an already persisted snapshot follow later state changes, so the progress
  // list would only ever show the final state.
  const emitSteps = () => options.onSteps?.(steps.map((step) => ({ ...step })));
  emitSteps();
  let readCalls = 0;

  for (const [index, document] of documents.entries()) {
    // The quota is already exhausted by the earlier documents: another request would only earn a
    // library_research_step_limit from the server and fail the whole message. The remaining
    // documents are skipped and the evidence already read is injected as usual.
    if (readCalls >= MAX_DIRECT_READ_CALLS) break;
    let cursor: string | null | undefined;
    const seenCursors = new Set<string>();
    const sections: LibraryReadResult["sections"] = [];
    let combined: LibraryReadResult | undefined;
    let documentGraphemes = 0;

    steps[index]!.status = "running";
    emitSteps();

    let notFound = false;
    try {
      for (let page = 0; ; page += 1) {
        throwIfAborted(options.signal);
        const args: LibraryReadArgs = {
          docId: document.docId,
          source: document.source,
          ...(cursor ? { cursor } : {}),
        };
        const toolCallId = `direct:${document.source}:${document.docId}:${page + 1}`;
        const response = await executeReadWithRetry(options, args, toolCallId);
        readCalls += 1;
        if (response.quota) options.onQuota?.(response.quota);
        let read = response.result;
        if (
          (read.source && read.source !== document.source) ||
          (read.docId && read.docId !== document.docId)
        ) {
          throw new LibraryAgentError(
            "Library read returned a different document identity",
            "library_source_error",
          );
        }
        const confirmation = buildLibraryReadConfirmation(
          read,
          args,
          options.config,
        );
        if (confirmation) {
          if (!sensitiveChoice) {
            sensitiveChoice = await options.requestConfirmation(confirmation);
          }
          if (sensitiveChoice === "cancel") throw new LibraryResearchCancelledError();
          if (sensitiveChoice === "redact") {
            read = applyServerRedactedLibraryRead(read);
          }
        }

        sections.push(...read.sections);
        documentGraphemes += read.sections.reduce(
          (sum, section) => sum + graphemeCount(section.text),
          0,
        );
        combined = {
          ...(combined ?? read),
          title: combined?.title || read.title || document.title,
          url: combined?.url || read.url || document.url || "",
          docId: document.docId,
          source: document.source,
          lastEdited: read.lastEdited || combined?.lastEdited || document.lastEdited,
          sections,
          nextCursor: read.nextCursor,
        };

        const nextCursor = read.nextCursor?.trim();
        if (!nextCursor) break;
        if (seenCursors.has(nextCursor)) {
          throw new LibraryAgentError(
            "Library read returned a repeated cursor",
            "library_source_error",
          );
        }
        // Stop here once the budget or the quota runs out: combined.nextCursor is non-empty, so
        // the envelope is marked truncated and the model knows it saw only the beginning rather
        // than drawing conclusions from a fragment.
        if (documentGraphemes >= charBudget) break;
        if (readCalls >= MAX_DIRECT_READ_CALLS) break;
        seenCursors.add(nextCursor);
        cursor = nextCursor;
      }
    } catch (error) {
      // One deleted or unauthorized document (404) must not take down the whole message: evidence
      // for the other selected documents is still read and injected, and only this one is marked
      // failed. The agent path makes the same trade-off, turning a 404 into a tool result and
      // carrying on. Other errors, including failures after rate-limit retries, still propagate.
      if (!isLibraryNotFoundError(error)) throw error;
      notFound = true;
      // The server counts a read when it reserves the call and does not refund a failed one, so
      // the 404 uses up quota too. Leaving it out would send one request too many near the
      // ceiling, earn a library_research_step_limit, and fail the whole message, undoing the
      // per-document tolerance above.
      readCalls += 1;
    }

    // A 404 partway through paging: the pages already read are real evidence and stay in (combined
    // still carries a cursor, so the envelope is marked truncated). A 404 on the first page means
    // nothing was read for this document, so it is skipped entirely.
    if (combined) {
      reads.push(combined);
      readDocuments.push(document);
    }
    steps[index]!.status = notFound ? "failed" : "completed";
    emitSteps();
  }

  // When the 64-read cap breaks out of the main loop early, steps for documents that were never
  // reached are still pending. The message has long since been delivered, but those pending steps
  // keep the step list spinning on "retrieving". Those documents really were not read, so failed
  // is the honest terminal state, and no new enum value is needed.
  if (steps.some((step) => step.status === "pending")) {
    for (const step of steps) {
      if (step.status === "pending") step.status = "failed";
    }
    emitSteps();
  }

  // Direct context citations persist document identity only. Section text and
  // snippets belong exclusively to the outbound request and must never reach
  // message storage or cross-device sync.
  const citations = reads.map((read, index) => {
    const document = readDocuments[index]!;
    return {
      index: index + 1,
      // Prefer the server URL; fall back to the URL from the picker, then to one rebuilt from the docId
      url: resolveLibraryCitationURL(
        read.url || document.url,
        document.docId,
        document.source,
      ),
      title: read.title || document.title,
      docId: document.docId,
      source: document.source,
      lastEdited: read.lastEdited || document.lastEdited,
    } satisfies Citation;
  });

  return {
    // When every selected document 404s (deleted or access revoked) there is no evidence at all: the empty array is rendered by the assembler as libraryEmptyEntry.
    entries: buildLibraryContextEntries(
      reads,
      resolveDirectContextCharBudget(options.config, options.modelContextLength),
    ),
    citations,
  };
}

export function libraryDocumentRefsFromCitations(
  citations: Citation[] | undefined,
): LibraryDocumentRef[] {
  if (!citations) return [];
  return dedupeLibraryDocumentRefs(
    citations.flatMap((citation) => {
      if (
        !citation.docId ||
        (citation.source !== "notion" && citation.source !== "google")
      ) {
        return [];
      }
      return [
        {
          docId: citation.docId,
          source: citation.source,
          title: citation.title?.trim() || citation.docId,
          ...(isTrustedLibraryURL(citation.url, citation.source)
            ? { url: citation.url }
            : {}),
          ...(citation.lastEdited ? { lastEdited: citation.lastEdited } : {}),
        },
      ];
    }),
  );
}

export function libraryDocumentRefsToPendingCitations(
  documents: LibraryDocumentRef[],
): Citation[] {
  return dedupeLibraryDocumentRefs(documents).map((document, index) => ({
    index: index + 1,
    url: resolveLibraryCitationURL(
      document.url,
      document.docId,
      document.source,
    ),
    title: document.title,
    docId: document.docId,
    source: document.source,
    lastEdited: document.lastEdited,
  }));
}

export function dedupeLibraryDocumentRefs(
  documents: LibraryDocumentRef[],
): LibraryDocumentRef[] {
  const seen = new Set<string>();
  const result: LibraryDocumentRef[] = [];
  for (const document of documents) {
    const docId = document.docId.trim();
    if (!docId) continue;
    const key = `${document.source}:${docId}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push({ ...document, docId });
  }
  return result;
}

/**
 * Convert the documents that were read into [D] library items (truncated to the budget; no XML escaping, the assembler escapes uniformly).
 *
 * Exported so the server retrieval path can reuse it: `documents[]` is field-for-field identical
 * to a read result, and sharing one builder guarantees both paths show the model the same
 * evidence format, truncation markers and citation numbering.
 */
export function buildLibraryContextEntries(
  reads: LibraryReadResult[],
  charBudget: number,
): LibraryEntry[] {
  const sizes = reads.map((read) =>
    read.sections.reduce((sum, section) => sum + graphemeCount(section.text), 0),
  );
  const allowances = allocateFairShare(sizes, charBudget);
  return reads.map((read, index) => {
    const clipped = clipSections(read.sections, allowances[index] ?? 0);
    // A cursor left over means paging stopped on budget or quota during the read phase, so the
    // body itself is a fragment; read.truncated means server retrieval truncated in one shot
    // (no paging, no cursor to leave behind). Looking only at the clipSections result misses both.
    const truncated = clipped.truncated || Boolean(read.nextCursor?.trim()) || Boolean(read.truncated);
    const text = clipped.sections
      .map((section) => {
        const heading = section.heading?.trim();
        return heading ? `${heading}\n${section.text}` : section.text;
      })
      .join("\n\n");
    // Truncation is conveyed to the model ("only the beginning was seen") by the truncated attribute + the oriveo-library note.
    return {
      citation: index + 1,
      title: read.title,
      ...(truncated ? { truncated: true } : {}),
      text,
    };
  });
}

/**
 * Spread the budget across documents by max-min fair share: split evenly first, then hand the
 * unused share of short documents back to the long ones.
 *
 * First come, first served is wrong here because selection order does not express importance: a
 * long document selected first eats the entire budget and the rest contribute nothing, while the
 * user still sees a citation list with all N documents in it.
 */
function allocateFairShare(sizes: number[], budget: number): number[] {
  const allowances = sizes.map(() => 0);
  let remaining = Math.max(0, budget);
  let pending = sizes.length;
  const order = sizes
    .map((size, index) => ({ size, index }))
    .sort((left, right) => left.size - right.size);
  for (const { size, index } of order) {
    const share = Math.floor(remaining / pending);
    const take = Math.min(size, share);
    allowances[index] = take;
    remaining -= take;
    pending -= 1;
  }
  return allowances;
}

function clipSections(
  sections: LibraryReadSection[],
  allowance: number,
): { sections: LibraryReadSection[]; truncated: boolean } {
  let remaining = allowance;
  const kept: LibraryReadSection[] = [];
  for (const section of sections) {
    const size = graphemeCount(section.text);
    if (size <= remaining) {
      kept.push(section);
      remaining -= size;
      continue;
    }
    if (remaining > 0) {
      kept.push({ ...section, text: takeGraphemes(section.text, remaining) });
    }
    return { sections: kept, truncated: true };
  }
  return { sections: kept, truncated: false };
}

async function executeReadWithRetry(
  options: ReadLibraryDirectContextOptions,
  args: LibraryReadArgs,
  toolCallId: string,
): Promise<{ result: LibraryReadResult; quota?: LibraryQuota }> {
  try {
    return await options.executeRead(args, toolCallId, options.signal);
  } catch (error) {
    if (!isLibraryRateLimitError(error)) throw error;
    const retryAfter = Math.max(
      0,
      Math.min(5_000, Math.round(((error as LibraryAPIError).retryAfter ?? 1) * 1_000)),
    );
    await abortableDelay(retryAfter, options.signal);
    return options.executeRead(args, toolCallId, options.signal);
  }
}

function throwIfAborted(signal: AbortSignal): void {
  if (signal.aborted) throw new DOMException("Aborted", "AbortError");
}

function abortableDelay(ms: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) {
    return Promise.reject(new DOMException("Aborted", "AbortError"));
  }
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      globalThis.clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      reject(new DOMException("Aborted", "AbortError"));
    };
    const timer = globalThis.setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal.addEventListener("abort", onAbort, { once: true });
  });
}
