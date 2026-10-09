import { describe, it, expect } from "vitest";
import type { AIModel, Attachment } from "@oriveo/shared";
import {
  ATTACHMENT_TRANSPORTS,
  attachmentTransportProfile,
} from "@oriveo/core/providers/attachment-transport";
import {
  decideAttachmentRoute,
  originalFileBytes,
} from "../attachment-router";

const OPENAI_OFFICE_MIMES = [
  "application/pdf",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  "application/rtf",
  "text/rtf",
  "application/vnd.oasis.opendocument.text",
  "application/vnd.oasis.opendocument.spreadsheet",
  "application/vnd.oasis.opendocument.presentation",
];

function makeAttachment(overrides: Partial<Attachment> = {}): Attachment {
  return {
    id: "a-1",
    kind: "file",
    fileName: "test.docx",
    mimeType:
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    originalBase64Data: "ZmFrZQ==",
    extractedSizeBytes: 5000,
    ...overrides,
  };
}

function makeModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: "gpt-5",
    name: "GPT-5",
    capabilities: ["text", "image", "file"],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: "premium",
    nativeFileMimes: OPENAI_OFFICE_MIMES,
    pdfNativeDefault: false,
    ...overrides,
  };
}

describe("decideAttachmentRoute", () => {
  it("docx → OpenAI GPT-5 → native", () => {
    expect(
      decideAttachmentRoute(makeAttachment(), { transport: "openai_responses" }, makeModel())
    ).toBe("native");
  });

  it("docx → OpenAI gpt-4o-mini (whitelisted) → native", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment(),
        { transport: "openai_responses" },
        makeModel({ id: "gpt-4o-mini" })
      )
    ).toBe("native");
  });

  it("docx → OpenAI dall-e (no nativeFileMimes) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment(),
        { transport: "openai_responses" },
        makeModel({ id: "dall-e-3", nativeFileMimes: [] })
      )
    ).toBe("client_extract");
  });

  it("docx → OpenRouter+GPT-5 (no nativeFileMimes for docx) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment(),
        { transport: "openrouter_chat" },
        makeModel({ nativeFileMimes: ["application/pdf"] })
      )
    ).toBe("client_extract");
  });

  it("docx → Anthropic (no docx in nativeFileMimes) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment(),
        { transport: "anthropic_messages" },
        makeModel({ nativeFileMimes: ["application/pdf"] })
      )
    ).toBe("client_extract");
  });

  it("docx → DeepSeek (no nativeFileMimes) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment(),
        { transport: "deepseek_chat" },
        makeModel({ nativeFileMimes: [] })
      )
    ).toBe("client_extract");
  });

  it("PDF → OpenAI GPT-5 (pdfNativeDefault=false) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({ mimeType: "application/pdf", fileName: "a.pdf" }),
        { transport: "openai_responses" },
        makeModel({ pdfNativeDefault: false })
      )
    ).toBe("client_extract");
  });

  it("PDF → Anthropic (pdfNativeDefault=false) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({ mimeType: "application/pdf", fileName: "a.pdf" }),
        { transport: "anthropic_messages" },
        makeModel({
          nativeFileMimes: ["application/pdf"],
          pdfNativeDefault: false,
        })
      )
    ).toBe("client_extract");
  });

  it("PDF → Gemini (pdfNativeDefault=true) → native (D28)", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({ mimeType: "application/pdf", fileName: "a.pdf" }),
        { transport: "gemini_generate" },
        makeModel({
          nativeFileMimes: ["application/pdf"],
          pdfNativeDefault: true,
        })
      )
    ).toBe("native");
  });

  it("scanned_pdf → GPT-5 → native (D1 fallback)", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({
          mimeType: "application/pdf",
          fileName: "scan.pdf",
          extractionErrorCode: "scanned_pdf",
        }),
        { transport: "openai_responses" },
        makeModel({ pdfNativeDefault: false })
      )
    ).toBe("native");
  });

  it("scanned_pdf → Claude → native (D1 fallback)", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({
          mimeType: "application/pdf",
          fileName: "scan.pdf",
          extractionErrorCode: "scanned_pdf",
        }),
        { transport: "anthropic_messages" },
        makeModel({
          nativeFileMimes: ["application/pdf"],
          pdfNativeDefault: false,
        })
      )
    ).toBe("native");
  });

  it("scanned_pdf → DeepSeek (no native PDF) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({
          mimeType: "application/pdf",
          fileName: "scan.pdf",
          extractionErrorCode: "scanned_pdf",
        }),
        { transport: "deepseek_chat" },
        makeModel({ nativeFileMimes: [] })
      )
    ).toBe("client_extract");
  });

  it("oversized file → client_extract (OOM defense)", () => {
    expect(
      decideAttachmentRoute(
        // 21MB of original bytes > the 20MB Gemini threshold; the comparison happens even when extractedSizeBytes is missing
        makeAttachment({ originalBase64Data: "A".repeat(28 * 1024 * 1024), extractedSizeBytes: undefined }),
        { transport: "gemini_generate" },
        makeModel()
      )
    ).toBe("client_extract");
  });

  it("no originalBase64Data → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({ originalBase64Data: undefined }),
        { transport: "openai_responses" },
        makeModel()
      )
    ).toBe("client_extract");
  });

  it("image kind -> client_extract (images take their own image_url path)", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({ kind: "image" }),
        { transport: "openai_responses" },
        makeModel()
      )
    ).toBe("client_extract");
  });
});

describe("originalFileBytes (derived from the raw bytes themselves)", () => {
  it("converts from the base64 length and padding", () => {
    expect(originalFileBytes(makeAttachment({ originalBase64Data: "ZmFrZQ==" }))).toBe(4);
    expect(originalFileBytes(makeAttachment({ originalBase64Data: "ZmFrZTE=" }))).toBe(5);
    expect(originalFileBytes(makeAttachment({ originalBase64Data: "ZmFrZTEy" }))).toBe(6);
    expect(originalFileBytes(makeAttachment({ originalBase64Data: undefined }))).toBe(0);
  });
});

const PDF = { mimeType: "application/pdf", fileName: "a.pdf" };

describe("line levels", () => {
  it("a line without a native block: the allowlist, however complete, still goes to text", () => {
    for (const transport of ["openai_chat", "relay_openai_chat", "moonshot_chat", "moonshot_browser_direct", "relay_llamacpp_native", "gemini_interactions"] as const) {
      expect(decideAttachmentRoute(makeAttachment(), { transport }, makeModel())).toBe("client_extract");
      expect(
        decideAttachmentRoute(
          makeAttachment({ ...PDF, extractionErrorCode: "scanned_pdf" }),
          { transport },
          makeModel({ pdfNativeDefault: true }),
        ),
      ).toBe("client_extract");
    }
  });

  it("alwaysWithTextFallback (relay / subscription): routing rules are exactly the same as direct", () => {
    for (const transport of ["relay_anthropic_messages", "relay_openai_responses", "relay_gemini_generate", "openai_subscription_codex", "grok_subscription_responses"] as const) {
      expect(attachmentTransportProfile(transport).nativeFiles).toBe("alwaysWithTextFallback");
      // Text PDF: follows pdfNativeDefault
      expect(decideAttachmentRoute(makeAttachment(PDF), { transport }, makeModel({ pdfNativeDefault: true }))).toBe("native");
      expect(decideAttachmentRoute(makeAttachment(PDF), { transport }, makeModel())).toBe("client_extract");
      // Scanned PDFs and allowlisted Office files: native
      expect(
        decideAttachmentRoute(makeAttachment({ ...PDF, extractionErrorCode: "scanned_pdf" }), { transport }, makeModel()),
      ).toBe("native");
      expect(decideAttachmentRoute(makeAttachment(), { transport }, makeModel())).toBe("native");
      // This connection already rejected file blocks: temporarily treated as off
      expect(
        decideAttachmentRoute(makeAttachment(), { transport, nativeFilesSuppressed: true }, makeModel()),
      ).toBe("client_extract");
    }
  });

  it("always (official direct): goes native according to the allowlist", () => {
    for (const transport of ["openai_responses", "anthropic_messages", "gemini_generate", "openrouter_chat"] as const) {
      expect(attachmentTransportProfile(transport).nativeFiles).toBe("always");
      expect(decideAttachmentRoute(makeAttachment(), { transport }, makeModel())).toBe("native");
    }
  });

  it("tool leg: only OpenRouter keeps native, the rest degrade to text", () => {
    const scanned = makeAttachment({ ...PDF, extractionErrorCode: "scanned_pdf" });
    expect(decideAttachmentRoute(scanned, { transport: "openrouter_chat", toolLoop: true }, makeModel())).toBe("native");
    for (const transport of ["openai_responses", "anthropic_messages", "gemini_generate", "relay_anthropic_messages"] as const) {
      expect(decideAttachmentRoute(scanned, { transport, toolLoop: true }, makeModel())).toBe("client_extract");
    }
  });

  it("every line has a declaration; a line without a native block must be off", () => {
    for (const transport of ATTACHMENT_TRANSPORTS) {
      const profile = attachmentTransportProfile(transport);
      expect(profile.wrapper === "xml-v1" || profile.wrapper === "markdown-v1").toBe(true);
      if (profile.nativeFileBlock === null) expect(profile.nativeFiles).toBe("off");
    }
  });

  it("native thresholds: Gemini 20MB, the rest 32MB", () => {
    expect(attachmentTransportProfile("gemini_generate").maxNativeBytes).toBe(20 * 1024 * 1024);
    expect(attachmentTransportProfile("openai_responses").maxNativeBytes).toBe(32 * 1024 * 1024);
    expect(attachmentTransportProfile("anthropic_messages").maxNativeBytes).toBe(32 * 1024 * 1024);
    expect(attachmentTransportProfile("openrouter_chat").maxNativeBytes).toBe(32 * 1024 * 1024);
  });
});
