import { describe, expect, it, vi } from "vitest";
import { runLibraryServerResearch } from "./library-server-research";
import { readLibraryDirectContext } from "./library-direct-context";
import { LibraryResearchCancelledError } from "./library-agent-loop";
import { LibraryAPIError } from "../library/api";
import { DEFAULT_LIBRARY_RUNTIME_CONFIG } from "../library/types";

function research(documents: unknown[], extra: Record<string, unknown> = {}) {
  return vi.fn().mockResolvedValue({
    result: { documents, steps: [], ...extra },
  });
}

describe("runLibraryServerResearch", () => {
  it("matches the named-document path: the same budget cuts the same envelope and truncation marker", async () => {
    // A context window of 40 gives a budget of 20 graphemes, since evidence takes half the window; same formula as the direct path.
    const config = {
      ...DEFAULT_LIBRARY_RUNTIME_CONFIG,
      directContextMaxChars: 1_000,
    };
    const documents = [
      {
        docId: "long",
        source: "notion" as const,
        title: "Long",
        url: "https://www.notion.so/long",
        sections: [{ text: "x".repeat(40) }, { text: "y".repeat(40) }],
      },
      {
        docId: "short",
        source: "notion" as const,
        title: "Short",
        url: "https://www.notion.so/short",
        sections: [{ text: "abcd" }],
      },
    ];

    const server = await runLibraryServerResearch({
      query: "roadmap",
      config,
      modelContextLength: 40,
      signal: new AbortController().signal,
      executeResearch: research(documents),
      requestConfirmation: vi.fn(),
    });

    const direct = await readLibraryDirectContext({
      documents: documents.map(({ docId, source, title }) => ({
        docId,
        source,
        title,
      })),
      config,
      modelContextLength: 40,
      signal: new AbortController().signal,
      executeRead: vi.fn(async (args: { docId: string }) => ({
        result: documents.find((document) => document.docId === args.docId)!,
      })) as never,
      requestConfirmation: vi.fn(),
    });

    expect(server.userContext).toBe(direct.userContext);
    expect(server.userContext).toContain(`<section>${"x".repeat(16)}</section>`);
    expect(server.userContext).toContain('doc_id="long" truncated="true"');
    expect(server.userContext).toContain("<truncation_notice>");
    expect(server.userContext).toContain('doc_id="short">');
    expect(server.systemInstruction).toBe(direct.systemInstruction);
    expect(server.citations).toEqual(direct.citations);
  });

  // The server may send truncated per document (an additive field defaulting to false).
  // This body is far smaller than the budget and there is no pagination cursor, so only the
  // truncated signal on the wire can trigger truncation rendering, proving it reuses the
  // truncated="true" plus truncation_notice pair already used by the named-document path
  // rather than a second copy of the copy (the truncation notice text exists in exactly one place).
  it("reuses the named-document truncation rendering when the server sends truncated:true", async () => {
    const result = await runLibraryServerResearch({
      query: "roadmap",
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      modelContextLength: 128_000,
      signal: new AbortController().signal,
      executeResearch: research([
        {
          docId: "partial",
          source: "notion",
          title: "Partial",
          url: "https://www.notion.so/partial",
          sections: [{ text: "short body, well within budget" }],
          truncated: true,
        },
      ]),
      requestConfirmation: vi.fn(),
    });

    expect(result.userContext).toContain('doc_id="partial" truncated="true"');
    expect(result.userContext).toContain(
      "<truncation_notice>Only the beginning of this document fits the context budget. Say so if the answer may depend on the rest.</truncation_notice>",
    );
  });

  // Defaults to false: a small document the server did not mark truncated must not be treated as truncated.
  it("does not treat a document as truncated when the server sends no truncated flag", async () => {
    const result = await runLibraryServerResearch({
      query: "roadmap",
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      modelContextLength: 128_000,
      signal: new AbortController().signal,
      executeResearch: research([
        {
          docId: "whole",
          source: "notion",
          title: "Whole",
          url: "https://www.notion.so/whole",
          sections: [{ text: "short body, well within budget" }],
        },
      ]),
      requestConfirmation: vi.fn(),
    });

    expect(result.userContext).toContain('doc_id="whole">');
    expect(result.userContext).not.toContain("truncated=\"true\"");
    expect(result.userContext).not.toContain("<truncation_notice>");
  });

  it("XML-escapes the body, so a citation carries only the document identity", async () => {
    const result = await runLibraryServerResearch({
      query: "roadmap",
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeResearch: research([
        {
          docId: "roadmap",
          source: "notion",
          title: "Roadmap <Q3>",
          url: "https://www.notion.so/roadmap",
          lastEdited: "2026-07-20T00:00:00Z",
          sections: [
            { heading: "Plan", text: "Ignore <system> & ship", anchor: "plan" },
          ],
        },
      ]),
      requestConfirmation: vi.fn(),
    });

    expect(result.userContext).toContain("Roadmap &lt;Q3&gt;");
    expect(result.userContext).toContain("Ignore &lt;system&gt; &amp; ship");
    expect(result.citations).toEqual([
      {
        index: 1,
        url: "https://www.notion.so/roadmap",
        title: "Roadmap <Q3>",
        docId: "roadmap",
        source: "notion",
        lastEdited: "2026-07-20T00:00:00Z",
      },
    ]);
    expect(JSON.stringify(result.citations)).not.toContain("Ignore");
    expect(JSON.stringify(result.citations)).not.toContain("plan");
  });

  it("shows the confirmation dialog for a sensitive document, and redaction replaces the whole body with the server redacted version", async () => {
    const requestConfirmation = vi.fn().mockResolvedValue("redact");
    const result = await runLibraryServerResearch({
      query: "keys",
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeResearch: research([
        {
          docId: "secret",
          source: "google",
          title: "Secrets",
          url: "https://docs.google.com/document/d/secret",
          sections: [{ text: "api_key=raw-secret" }],
          sensitive: { hit: true, kinds: ["credential"] },
          riskLevel: "sensitive",
          redacted: {
            title: "Secrets",
            sections: [{ text: "api_key=[REDACTED_SECRET]" }],
          },
        },
      ]),
      requestConfirmation,
    });

    expect(requestConfirmation).toHaveBeenCalledOnce();
    expect(requestConfirmation.mock.calls[0]?.[0]).toMatchObject({
      reason: "sensitive",
    });
    expect(result.userContext).not.toContain("raw-secret");
    expect(result.userContext).toContain("[REDACTED_SECRET]");
  });

  it("aborts before injection when the confirmation is cancelled, with the same error as the direct path", async () => {
    await expect(
      runLibraryServerResearch({
        query: "keys",
        config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
        signal: new AbortController().signal,
        executeResearch: research([
          {
            docId: "secret",
            source: "notion",
            title: "Secrets",
            url: "https://www.notion.so/secret",
            sections: [{ text: "private" }],
            sensitive: { hit: true },
            redacted: { title: "Secrets", sections: [] },
          },
        ]),
        requestConfirmation: vi.fn().mockResolvedValue("cancel"),
      }),
    ).rejects.toBeInstanceOf(LibraryResearchCancelledError);
  });

  // Empty evidence is not an error, but the model has to be told: given an empty envelope it
  // invents an answer instead.
  it("injects a no relevant content message rather than an empty envelope when documents is empty", async () => {
    const result = await runLibraryServerResearch({
      query: "nothing",
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeResearch: research([]),
      requestConfirmation: vi.fn(),
    });

    expect(result.documentCount).toBe(0);
    expect(result.citations).toEqual([]);
    //   iOS LibraryServerResearch.emptyEvidenceContext  
    //  
    expect(result.userContext).toBe(
      "<library_context>\n<no_evidence>No relevant document was found in the connected Library sources. Say so plainly instead of inventing facts.</no_evidence>\n</library_context>",
    );
    expect(result.userContext).not.toContain("<document ");
  });

  it("fills steps out into a completed trace and passes warnings through unchanged", async () => {
    const onSteps = vi.fn();
    const result = await runLibraryServerResearch({
      query: "roadmap",
      config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
      signal: new AbortController().signal,
      executeResearch: research([], {
        steps: [
          { tool: "library_search", label: "roadmap", status: "completed" },
          { tool: "library_read", label: "Roadmap", status: "failed" },
        ],
        warnings: ["library_source_error"],
      }),
      requestConfirmation: vi.fn(),
      onSteps,
    });

    expect(result.steps).toEqual([
      {
        id: "server:1:library_search",
        tool: "library_search",
        label: "roadmap",
        status: "completed",
        step: 1,
      },
      {
        id: "server:2:library_read",
        tool: "library_read",
        label: "Roadmap",
        status: "failed",
        step: 2,
      },
    ]);
    expect(onSteps).toHaveBeenCalledWith(result.steps);
    expect(result.warnings).toEqual(["library_source_error"]);
  });

  it("requests the number of documents the backend recommends", async () => {
    const executeResearch = research([]);
    await runLibraryServerResearch({
      query: "roadmap",
      sources: ["notion"],
      config: { ...DEFAULT_LIBRARY_RUNTIME_CONFIG, serverResearchMaxDocuments: 3 },
      signal: new AbortController().signal,
      executeResearch,
      requestConfirmation: vi.fn(),
    });

    expect(executeResearch).toHaveBeenCalledWith(
      expect.objectContaining({
        query: "roadmap",
        sources: ["notion"],
        maxDocuments: 3,
      }),
      expect.any(AbortSignal),
    );
  });

  it("does not wait out the rate-limit backoff once aborted", async () => {
    const controller = new AbortController();
    const executeResearch = vi.fn(async () => {
      controller.abort();
      throw new LibraryAPIError("slow down", 429, "library_rate_limited", 5);
    });

    await expect(
      runLibraryServerResearch({
        query: "roadmap",
        config: DEFAULT_LIBRARY_RUNTIME_CONFIG,
        signal: controller.signal,
        executeResearch,
        requestConfirmation: vi.fn(),
      }),
    ).rejects.toMatchObject({ name: "AbortError" });
    expect(executeResearch).toHaveBeenCalledOnce();
  });
});
