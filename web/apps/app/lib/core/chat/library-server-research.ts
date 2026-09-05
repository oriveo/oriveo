import { isLibraryRateLimitError, LibraryAPIError } from "../library/api";
import {
  resolveDirectContextCharBudget,
  resolveServerResearchMaxDocuments,
} from "../library/types";
import type {
  LibraryCitation,
  LibraryConfirmationChoice,
  LibraryConfirmationRequest,
  LibraryProvider,
  LibraryQuota,
  LibraryReadResult,
  LibraryResearchDocument,
  LibraryResearchResult,
  LibraryResearchStep,
  LibraryRuntimeConfig,
} from "../library/types";
import {
  applyServerRedactedLibraryRead,
  buildLibraryReadConfirmation,
  LibraryResearchCancelledError,
  resolveLibraryCitationURL,
} from "./library-agent-loop";
import {
  buildLibraryContextEnvelope,
  EMPTY_LIBRARY_CONTEXT,
  LIBRARY_CONTEXT_SYSTEM_INSTRUCTION,
  type LibraryDirectContextResult,
} from "./library-direct-context";

export interface LibraryServerResearchResult extends LibraryDirectContextResult {
  /** Narrowed to LibraryCitation: the source is always a known library source, and fallback paths have to fill it in with this type. */
  citations: LibraryCitation[];
  /** The completed trace, filled in at once and rendered by the existing LibraryResearchStep progress list. */
  steps: LibraryResearchStep[];
  /** Degradation signal for partly failed sources or documents. A warning is not a failure; the remaining evidence is still usable. */
  warnings: string[];
  documentCount: number;
}

export interface RunLibraryServerResearchOptions {
  query: string;
  /** Omitted means all connected sources. */
  sources?: LibraryProvider[];
  config: LibraryRuntimeConfig;
  /** Context window of the selected model, which sets the body injection budget; treated as a conservative window when unknown. */
  modelContextLength?: number;
  signal: AbortSignal;
  executeResearch: (
    args: {
      query: string;
      sources?: LibraryProvider[];
      maxDocuments: number;
      toolCallId: string;
    },
    signal: AbortSignal,
  ) => Promise<{ result: LibraryResearchResult; quota?: LibraryQuota }>;
  requestConfirmation: (
    request: LibraryConfirmationRequest,
  ) => Promise<LibraryConfirmationChoice>;
  onQuota?: (quota: LibraryQuota) => void;
  onSteps?: (steps: LibraryResearchStep[]) => void;
}

/**
 * Server-side retrieval: one call returns the evidence, which then goes through exactly the same
 * injection pipeline as the selected-documents path (envelope, max-min budget allocation,
 * grapheme truncation, citations that store identity only).
 *
 * The envelope is deliberately not assembled a second time here: the evidence structures of the
 * two paths are field-for-field identical, and two builders would inevitably truncate the same
 * evidence to different lengths and disagree on citation numbering.
 */
export async function runLibraryServerResearch(
  options: RunLibraryServerResearchOptions,
): Promise<LibraryServerResearchResult> {
  throwIfAborted(options.signal);
  const response = await executeResearchWithRetry(options);
  if (response.quota) options.onQuota?.(response.quota);
  throwIfAborted(options.signal);

  const result = response.result;
  const steps = mapResearchSteps(result);
  options.onSteps?.(steps);

  const reads: LibraryReadResult[] = [];
  // Ask once when several documents in one retrieval hit sensitive content, and apply that choice
  // to the remaining hits. Prompting per document would stack four or five dialogs on the send
  // path, while the user has one attitude to this batch of evidence.
  // Scoped to this send only: sensitive content varies per message, so remembering it across
  // messages would disable the gate.
  let sensitiveChoice: LibraryConfirmationChoice | undefined;
  for (const document of result.documents) {
    const read = toLibraryReadResult(document);
    const confirmation = buildLibraryReadConfirmation(
      read,
      { docId: document.docId, source: document.source },
      options.config,
    );
    if (!confirmation) {
      reads.push(read);
      continue;
    }
    if (!sensitiveChoice) {
      sensitiveChoice = await options.requestConfirmation(confirmation);
      throwIfAborted(options.signal);
    }
    if (sensitiveChoice === "cancel") throw new LibraryResearchCancelledError();
    reads.push(
      sensitiveChoice === "redact" ? applyServerRedactedLibraryRead(read) : read,
    );
  }

  // Citations carry document identity only: body text and snippets belong to this outbound request
  // and never reach message storage or cross-client sync.
  // Numbering follows the order the server already sorted `documents` into; the client does not sort again.
  const citations = reads.map((read, index) => {
    const document = result.documents[index]!;
    return {
      index: index + 1,
      url: resolveLibraryCitationURL(
        read.url || document.url,
        document.docId,
        document.source,
      ),
      title: read.title || document.title,
      docId: document.docId,
      source: document.source,
      lastEdited: read.lastEdited || document.lastEdited,
    } satisfies LibraryCitation;
  });

  return {
    systemInstruction: LIBRARY_CONTEXT_SYSTEM_INSTRUCTION,
    userContext: reads.length === 0
      ? EMPTY_LIBRARY_CONTEXT
      : buildLibraryContextEnvelope(
        reads,
        resolveDirectContextCharBudget(
          options.config,
          options.modelContextLength,
        ),
      ),
    citations,
    steps,
    warnings: result.warnings ?? [],
    documentCount: reads.length,
  };
}

/** documents[] is field-for-field identical to a read result; the conversion only supplies the optional field names of the read side. */
function toLibraryReadResult(
  document: LibraryResearchDocument,
): LibraryReadResult {
  return {
    docId: document.docId,
    source: document.source,
    title: document.title,
    url: document.url,
    ...(document.lastEdited ? { lastEdited: document.lastEdited } : {}),
    sections: Array.isArray(document.sections) ? document.sections : [],
    ...(document.sensitive ? { sensitive: document.sensitive } : {}),
    ...(document.riskLevel ? { riskLevel: document.riskLevel } : {}),
    ...(document.redacted ? { redacted: document.redacted } : {}),
    // The server marked this document as sending only its beginning: pass that through to
    // buildLibraryContextEnvelope so it renders with the existing truncated="true" and
    // truncation_notice, rather than deciding a second time here.
    ...(document.truncated ? { truncated: true } : {}),
  };
}

function mapResearchSteps(result: LibraryResearchResult): LibraryResearchStep[] {
  const steps = result.steps ?? [];
  return steps.map((step, index) => ({
    id: `server:${index + 1}:${step.tool}`,
    tool: normalizeStepTool(step.tool),
    label: step.label,
    status: normalizeStepStatus(step.status),
    step: index + 1,
  }));
}

function normalizeStepTool(tool: string): LibraryResearchStep["tool"] {
  return tool === "library_search" ||
    tool === "library_list" ||
    tool === "library_read" ||
    tool === "synthesize"
    ? tool
    : "library_search";
}

function normalizeStepStatus(status: string): LibraryResearchStep["status"] {
  return status === "pending" ||
    status === "running" ||
    status === "completed" ||
    status === "failed"
    ? status
    : "completed";
}

/**
 * One rate-limit backoff retry, on the same terms as the selected-documents path.
 *
 * Keeping toolCallId unchanged is deliberate: a replay with the same researchId, toolCallId and
 * arguments does not consume quota twice, while a fresh id would be counted as a second retrieval.
 */
async function executeResearchWithRetry(
  options: RunLibraryServerResearchOptions,
): Promise<{ result: LibraryResearchResult; quota?: LibraryQuota }> {
  const args = {
    query: options.query,
    ...(options.sources && options.sources.length > 0
      ? { sources: options.sources }
      : {}),
    maxDocuments: resolveServerResearchMaxDocuments(options.config),
    toolCallId: "research:1",
  };
  try {
    return await options.executeResearch(args, options.signal);
  } catch (error) {
    if (error instanceof LibraryAPIError && error.quota) {
      options.onQuota?.(error.quota);
    }
    if (!isLibraryRateLimitError(error)) throw error;
    const retryAfter = Math.max(
      0,
      Math.min(
        5_000,
        Math.round(((error as LibraryAPIError).retryAfter ?? 1) * 1_000),
      ),
    );
    await abortableDelay(retryAfter, options.signal);
    return options.executeResearch(args, options.signal);
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
