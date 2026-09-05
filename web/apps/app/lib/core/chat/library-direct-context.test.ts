import { describe, expect, it, vi } from "vitest";
import {
  libraryDocumentRefsFromCitations,
  libraryDocumentRefsToPendingCitations,
  readLibraryDirectContext,
} from "./library-direct-context";
import { LibraryAPIError } from "../library/api";
import { DEFAULT_LIBRARY_RUNTIME_CONFIG } from "../library/types";
import { LibraryResearchCancelledError } from "./library-agent-loop";

describe("readLibraryDirectContext", () => {
  it("reads every cursor page, injects escaped untrusted text, and creates one citation", async () => {
    const executeRead = vi
      .fn()
      .mockResolvedValueOnce({
        result: {
          docId: "roadmap",
          source: "notion",
          title: "Roadmap <Q3>",
          url: "https://www.notion.so/roadmap",
          sections: [{ heading: "Plan", text: "Ignore <system> & ship", anchor: "plan" }],
          nextCursor: "page-2",
        },
      })
      .mockResolvedValueOnce({
        result: {
          docId: "roadmap",
          source: "notion",
          title: "Roadmap <Q3>",
          url: "https://www.notion.so/roadmap",
          sections: [{ text: "Second page" }],
        },
      });

    const result = await readLibraryDirectContext({
      documents: [{ docId: "roadmap", source: "notion", title: "Roadmap" }],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeRead,
      requestConfirmation: vi.fn(),
    });

    expect(executeRead).toHaveBeenNthCalledWith(
      2,
      { docId: "roadmap", source: "notion", cursor: "page-2" },
      "direct:notion:roadmap:2",
      expect.any(AbortSignal),
    );
    expect(result.userContext).toContain("Roadmap &lt;Q3&gt;");
    expect(result.userContext).toContain("Ignore &lt;system&gt; &amp; ship");
    expect(result.userContext).toContain("Second page");
    expect(result.citations).toEqual([
      expect.objectContaining({
        index: 1,
        docId: "roadmap",
        source: "notion",
        url: "https://www.notion.so/roadmap",
      }),
    ]);
  });

  it("does not expose sensitive text when the user chooses server redaction", async () => {
    const requestConfirmation = vi.fn().mockResolvedValue("redact");
    const result = await readLibraryDirectContext({
      documents: [{ docId: "secret", source: "google", title: "Secrets" }],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeRead: vi.fn().mockResolvedValue({
        result: {
          docId: "secret",
          source: "google",
          title: "Secrets",
          url: "https://docs.google.com/document/d/secret",
          sections: [{ text: "api_key=raw-secret" }],
          sensitive: { hit: true, kinds: ["credential"] },
          redacted: {
            title: "Secrets",
            sections: [{ text: "api_key=[REDACTED_SECRET]" }],
          },
        },
      }),
      requestConfirmation,
    });

    expect(requestConfirmation).toHaveBeenCalledOnce();
    expect(result.userContext).not.toContain("raw-secret");
    expect(result.userContext).toContain("[REDACTED_SECRET]");
    expect(result.citations[0]?.snippet).toBeUndefined();
    expect(result.citations[0]?.anchor).toBeUndefined();
  });

  it("keeps document identity as a non-linkable reference when the source URL is untrusted", async () => {
    const result = await readLibraryDirectContext({
      documents: [{ docId: "roadmap", source: "notion", title: "Roadmap" }],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeRead: vi.fn().mockResolvedValue({
        result: {
          docId: "roadmap",
          source: "notion",
          title: "Roadmap",
          url: "https://notion.so.evil.example/roadmap",
          sections: [{ text: "request-only body", anchor: "private-heading" }],
        },
      }),
      requestConfirmation: vi.fn(),
    });

    expect(result.userContext).toContain("request-only body");
    expect(result.citations).toEqual([{
      index: 1,
      url: "library-context://notion/roadmap",
      title: "Roadmap",
      docId: "roadmap",
      source: "notion",
      lastEdited: undefined,
    }]);
    expect(JSON.stringify(result.citations)).not.toContain("request-only body");
    expect(JSON.stringify(result.citations)).not.toContain("private-heading");
  });

  it("stops before context injection when confirmation is cancelled", async () => {
    await expect(readLibraryDirectContext({
      documents: [{ docId: "secret", source: "notion", title: "Secrets" }],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeRead: vi.fn().mockResolvedValue({
        result: {
          title: "Secrets",
          url: "https://www.notion.so/secret",
          sections: [{ text: "private" }],
          sensitive: { hit: true },
        },
      }),
      requestConfirmation: vi.fn().mockResolvedValue("cancel"),
    })).rejects.toBeInstanceOf(LibraryResearchCancelledError);
  });

  // Selected documents are spliced into the message in full: without a budget, picking a few long ones blows the context and earns a provider 400
  it("splits the char budget fairly and marks clipped documents", async () => {
    const executeRead = vi.fn(async (args: { docId: string }) => ({
      result: {
        docId: args.docId,
        source: "notion",
        title: args.docId,
        url: `https://www.notion.so/${args.docId}`,
        sections: args.docId === "short"
          ? [{ text: "abcd" }]
          : [{ text: "x".repeat(40) }, { text: "y".repeat(40) }],
      },
    }));

    const result = await readLibraryDirectContext({
      documents: [
        { docId: "long", source: "notion", title: "Long" },
        { docId: "short", source: "notion", title: "Short" },
      ],
      // Context window 40 -> budget 20 graphemes (evidence takes half the window)
      config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, directContextMaxChars: 1_000 },
      modelContextLength: 40,
      signal: new AbortController().signal,
      executeRead: executeRead as never,
      requestConfirmation: vi.fn(),
    });

    // The short document goes in whole at 4 characters and the remaining 16 go to the long one, instead of the long one taking everything first come first served
    expect(result.userContext).toContain("abcd");
    expect(result.userContext).toContain(`<section>${"x".repeat(16)}</section>`);
    expect(result.userContext).not.toContain("yy");
    expect(result.userContext).toContain('doc_id="long" truncated="true"');
    expect(result.userContext).toContain("<truncation_notice>");
    // A document that was not clipped must not carry the truncation marker, or the model needlessly declares the evidence incomplete
    expect(result.userContext).toContain('doc_id="short">');
    // Clipping the body does not affect citations: a citation only carries document identity
    expect(result.citations.map((citation) => citation.docId)).toEqual(["long", "short"]);
  });

  it("keeps the whole document when it fits the budget", async () => {
    const result = await readLibraryDirectContext({
      documents: [{ docId: "roadmap", source: "notion", title: "Roadmap" }],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      modelContextLength: 128_000,
      signal: new AbortController().signal,
      executeRead: vi.fn().mockResolvedValue({
        result: {
          docId: "roadmap",
          source: "notion",
          title: "Roadmap",
          url: "https://www.notion.so/roadmap",
          sections: [{ text: " " }],
        },
      }),
      requestConfirmation: vi.fn(),
    });

    expect(result.userContext).toContain(" ");
    expect(result.userContext).not.toContain("truncated=");
  });

  it("never reads past the server document limit", async () => {
    const executeRead = vi.fn(async (args: { docId: string }) => ({
      result: {
        docId: args.docId,
        source: "notion",
        title: args.docId,
        url: `https://www.notion.so/${args.docId}`,
        sections: [{ text: "body" }],
      },
    }));

    const result = await readLibraryDirectContext({
      documents: Array.from({ length: 5 }, (_unused, index) => ({
        docId: `doc-${index}`,
        source: "notion" as const,
        title: `Doc ${index}`,
      })),
      config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, directMaxDocuments: 2 },
      signal: new AbortController().signal,
      executeRead: executeRead as never,
      requestConfirmation: vi.fn(),
    });

    expect(executeRead).toHaveBeenCalledTimes(2);
    expect(result.citations.map((citation) => citation.docId)).toEqual(["doc-0", "doc-1"]);
  });

  // Reading a whole document once produced a broad_read riskLevel on the server, which hit on 100% of
  // normal sends: picking three documents meant three "about to read a wide range" dialogs, with OK as
  // the only rational answer. The server stopped sending it and the client only honors the sensitive gate.
  it("no longer confirms broad_read or high_cost reads", async () => {
    const requestConfirmation = vi.fn();
    const result = await readLibraryDirectContext({
      documents: [
        { docId: "a", source: "notion", title: "A" },
        { docId: "b", source: "notion", title: "B" },
      ],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeRead: vi.fn(async (args: { docId: string }) => ({
        result: {
          docId: args.docId,
          source: "notion",
          title: args.docId,
          url: `https://www.notion.so/${args.docId}`,
          sections: [{ text: "body" }],
          riskLevel: args.docId === "a" ? "broad_read" : "high_cost",
        },
      })) as never,
      requestConfirmation,
    });

    expect(requestConfirmation).not.toHaveBeenCalled();
    expect(result.citations).toHaveLength(2);
  });

  // Several sensitive hits in one send ask once and apply the choice to the rest, instead of stacking dialogs along the send path.
  it("asks about sensitive content once per send and reuses the choice", async () => {
    const requestConfirmation = vi.fn().mockResolvedValue("redact");
    const sensitiveRead = (docId: string) => ({
      result: {
        docId,
        source: "notion",
        title: docId,
        url: `https://www.notion.so/${docId}`,
        sections: [{ text: `raw-secret-${docId}` }],
        sensitive: { hit: true, kinds: ["credential"] },
        redacted: { title: docId, sections: [{ text: `[REDACTED_${docId}]` }] },
      },
    });

    const result = await readLibraryDirectContext({
      documents: [
        { docId: "a", source: "notion", title: "A" },
        { docId: "b", source: "notion", title: "B" },
        { docId: "c", source: "notion", title: "C" },
      ],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeRead: vi.fn(async (args: { docId: string }) => sensitiveRead(args.docId)) as never,
      requestConfirmation,
    });

    expect(requestConfirmation).toHaveBeenCalledTimes(1);
    // The redact-and-continue choice made the first time applied to all three
    for (const docId of ["a", "b", "c"]) {
      expect(result.userContext).toContain(`[REDACTED_${docId}]`);
      expect(result.userContext).not.toContain(`raw-secret-${docId}`);
    }
  });

  // Paging on after the budget is full wastes a round trip and a server read quota unit, because the body
  // that comes back is guaranteed to be dropped whole by clipSections
  it("stops paging once the injected budget is full and marks the document truncated", async () => {
    const executeRead = vi.fn(async () => ({
      result: {
        docId: "long",
        source: "notion",
        title: "Long",
        url: "https://www.notion.so/long",
        sections: [{ text: "x".repeat(30) }],
        nextCursor: "next",
      },
    }));

    const result = await readLibraryDirectContext({
      documents: [{ docId: "long", source: "notion", title: "Long" }],
      // Context window 40 -> budget 20 graphemes, and the first page of 30 already overflows it
      config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, directContextMaxChars: 1_000 },
      modelContextLength: 40,
      signal: new AbortController().signal,
      executeRead: executeRead as never,
      requestConfirmation: vi.fn(),
    });

    expect(executeRead).toHaveBeenCalledOnce();
    expect(result.userContext).toContain('doc_id="long" truncated="true"');
    expect(result.userContext).toContain("<truncation_notice>");
  });

  // 64 is the server hard cap on reads for one research run and is **shared across all documents**:
  // counting 64 per document blows the quota once a few long documents are picked, failing the whole
  // message with an error that carries no copy
  it("stops before the server-side read ceiling instead of blowing through it", async () => {
    // Every page cursor must differ, or the duplicate-cursor loop guard fires first
    let page = 0;
    const executeRead = vi.fn(async (args: { docId: string }) => ({
      result: {
        docId: args.docId,
        source: "notion",
        title: args.docId,
        url: `https://www.notion.so/${args.docId}`,
        sections: [{ text: "body" }],
        nextCursor: `page-${(page += 1)}`,
      },
    }));

    const result = await readLibraryDirectContext({
      documents: [
        { docId: "a", source: "notion", title: "A" },
        { docId: "b", source: "notion", title: "B" },
      ],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      modelContextLength: 128_000,
      signal: new AbortController().signal,
      executeRead: executeRead as never,
      requestConfirmation: vi.fn(),
    });

    expect(executeRead).toHaveBeenCalledTimes(64);
    // The quota was used up on the first document and the second was never read; evidence already collected is still injected
    expect(result.citations.map((citation) => citation.docId)).toEqual(["a"]);
  });

  // Documents skipped at the hard cap must not leave their step pending: the message is already delivered,
  // while the step list would spin on "searching" forever. Pending is reclassified as failed rather than
  // adding a new enum value.
  it("marks steps for documents skipped by the read ceiling as failed instead of leaving them pending forever", async () => {
    let page = 0;
    const onSteps = vi.fn();
    const executeRead = vi.fn(async (args: { docId: string }) => ({
      result: {
        docId: args.docId,
        source: "notion",
        title: args.docId,
        url: `https://www.notion.so/${args.docId}`,
        sections: [{ text: "body" }],
        nextCursor: `page-${(page += 1)}`,
      },
    }));

    await readLibraryDirectContext({
      documents: [
        { docId: "a", source: "notion", title: "A" },
        { docId: "b", source: "notion", title: "B" },
      ],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      modelContextLength: 128_000,
      signal: new AbortController().signal,
      executeRead: executeRead as never,
      requestConfirmation: vi.fn(),
      onSteps,
    });

    const last = onSteps.mock.calls.at(-1)![0] as { id: string; status: string }[];
    expect(last).toEqual([
      { id: "direct:notion:a", tool: "library_read", label: "A", status: "completed", step: 1 },
      { id: "direct:notion:b", tool: "library_read", label: "B", status: "failed", step: 2 },
    ]);
  });

  // Research mode always had a step list, while the specified-documents path only showed a typing indicator:
  // with a few long documents picked, the user had no idea what was being waited on. The id / label / status
  // semantics match the other clients word for word.
  it("reports per-document progress with the cross-platform step identity", async () => {
    const onSteps = vi.fn();
    await readLibraryDirectContext({
      documents: [
        { docId: "a", source: "notion", title: "Doc A" },
        { docId: "b", source: "google", title: "Doc B" },
      ],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeRead: vi.fn(async (args: { docId: string }) => ({
        result: {
          docId: args.docId,
          source: args.docId === "a" ? "notion" : "google",
          title: args.docId,
          url: args.docId === "a"
            ? "https://www.notion.so/a"
            : "https://docs.google.com/document/d/b",
          sections: [{ text: "body" }],
        },
      })) as never,
      requestConfirmation: vi.fn(),
      onSteps,
    });

    // First report: everything pending (the label is the document title, not a bare docId)
    expect(onSteps.mock.calls[0]![0]).toEqual([
      { id: "direct:notion:a", tool: "library_read", label: "Doc A", status: "pending", step: 1 },
      { id: "direct:google:b", tool: "library_read", label: "Doc B", status: "pending", step: 2 },
    ]);
    // Final report: everything completed
    const last = onSteps.mock.calls.at(-1)![0] as { status: string }[];
    expect(last.map((step) => step.status)).toEqual(["completed", "completed"]);
  });

  // A single document being deleted or its permission revoked (404) must not fail the whole message and void the evidence from every other readable document
  it("skips a document that returns library_not_found and still injects the rest", async () => {
    const onSteps = vi.fn();
    const executeRead = vi.fn(async (args: { docId: string }) => {
      if (args.docId === "gone") {
        throw new LibraryAPIError("not found", 404, "library_not_found");
      }
      return {
        result: {
          docId: args.docId,
          source: "notion",
          title: args.docId,
          url: `https://www.notion.so/${args.docId}`,
          sections: [{ text: `body-${args.docId}` }],
        },
      };
    });

    const result = await readLibraryDirectContext({
      documents: [
        { docId: "a", source: "notion", title: "A" },
        { docId: "gone", source: "notion", title: "Gone" },
        { docId: "c", source: "notion", title: "C" },
      ],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      modelContextLength: 128_000,
      signal: new AbortController().signal,
      executeRead: executeRead as never,
      requestConfirmation: vi.fn(),
      onSteps,
    });

    expect(result.userContext).toContain("body-a");
    expect(result.userContext).toContain("body-c");
    expect(result.userContext).not.toContain("body-gone");
    // Citation identity must not shift because the middle document was skipped: entry 2 has to be c, not gone
    expect(result.citations).toEqual([
      expect.objectContaining({ index: 1, docId: "a" }),
      expect.objectContaining({ index: 2, docId: "c" }),
    ]);
    const last = onSteps.mock.calls.at(-1)![0] as { status: string }[];
    expect(last.map((step) => step.status)).toEqual([
      "completed",
      "failed",
      "completed",
    ]);
  });

  it("falls back to the no-evidence context when every selected document is gone", async () => {
    const onSteps = vi.fn();
    const result = await readLibraryDirectContext({
      documents: [
        { docId: "a", source: "notion", title: "A" },
        { docId: "b", source: "google", title: "B" },
      ],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeRead: vi.fn(async () => {
        throw new LibraryAPIError("not found", 404, "library_not_found");
      }) as never,
      requestConfirmation: vi.fn(),
      onSteps,
    });

    expect(result.userContext).toContain("<no_evidence>");
    expect(result.citations).toEqual([]);
    const last = onSteps.mock.calls.at(-1)![0] as { status: string }[];
    expect(last.map((step) => step.status)).toEqual(["failed", "failed"]);
  });

  // The 404 degrade must not swallow the rate-limit retry: after a 429 it still retries once and reads the evidence back
  it("still retries once after a rate-limit error", async () => {
    const executeRead = vi
      .fn()
      .mockRejectedValueOnce(
        new LibraryAPIError("slow down", 429, "library_rate_limited", 0),
      )
      .mockResolvedValueOnce({
        result: {
          docId: "roadmap",
          source: "notion",
          title: "Roadmap",
          url: "https://www.notion.so/roadmap",
          sections: [{ text: "retried body" }],
        },
      });

    const result = await readLibraryDirectContext({
      documents: [{ docId: "roadmap", source: "notion", title: "Roadmap" }],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeRead,
      requestConfirmation: vi.fn(),
    });

    expect(executeRead).toHaveBeenCalledTimes(2);
    expect(result.userContext).toContain("retried body");
    expect(result.citations).toHaveLength(1);
  });

  it("does not wait for rate-limit backoff after the request is already aborted", async () => {
    const controller = new AbortController();
    const executeRead = vi.fn(async () => {
      controller.abort();
      throw new LibraryAPIError(
        "slow down",
        429,
        "library_rate_limited",
        5,
      );
    });

    await expect(readLibraryDirectContext({
      documents: [{ docId: "roadmap", source: "notion", title: "Roadmap" }],
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: controller.signal,
      executeRead,
      requestConfirmation: vi.fn(),
    })).rejects.toMatchObject({ name: "AbortError" });
    expect(executeRead).toHaveBeenCalledOnce();
  });
});

describe("Library document reference persistence", () => {
  it("round-trips refs through existing citations and hides refs without a trusted URL", () => {
    const pending = libraryDocumentRefsToPendingCitations([
      { docId: "n-1", source: "notion", title: "Plan" },
      {
        docId: "g-1",
        source: "google",
        title: "Brief",
        url: "https://docs.google.com/document/d/g-1",
      },
    ]);

    expect(pending[0]?.url).toBe("library-context://notion/n-1");
    expect(pending[1]?.url).toBe("https://docs.google.com/document/d/g-1");
    expect(libraryDocumentRefsFromCitations(pending)).toEqual([
      { docId: "n-1", source: "notion", title: "Plan" },
      {
        docId: "g-1",
        source: "google",
        title: "Brief",
        url: "https://docs.google.com/document/d/g-1",
      },
    ]);
  });
});
