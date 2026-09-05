import { describe, it, expect } from "vitest";
import type { AIModel, Attachment } from "@oriveo/shared";
import {
  decideAttachmentRoute,
  maxNativeBytesFor,
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
      decideAttachmentRoute(makeAttachment(), "openAI", makeModel())
    ).toBe("native");
  });

  it("docx → OpenAI gpt-4o-mini (whitelisted) → native", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment(),
        "openAI",
        makeModel({ id: "gpt-4o-mini" })
      )
    ).toBe("native");
  });

  it("docx → OpenAI dall-e (no nativeFileMimes) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment(),
        "openAI",
        makeModel({ id: "dall-e-3", nativeFileMimes: [] })
      )
    ).toBe("client_extract");
  });

  it("docx → OpenRouter+GPT-5 (no nativeFileMimes for docx) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment(),
        "openRouter",
        makeModel({ nativeFileMimes: ["application/pdf"] })
      )
    ).toBe("client_extract");
  });

  it("docx → Anthropic (no docx in nativeFileMimes) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment(),
        "anthropic",
        makeModel({ nativeFileMimes: ["application/pdf"] })
      )
    ).toBe("client_extract");
  });

  it("docx → DeepSeek (no nativeFileMimes) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment(),
        "deepseek",
        makeModel({ nativeFileMimes: [] })
      )
    ).toBe("client_extract");
  });

  it("PDF → OpenAI GPT-5 (pdfNativeDefault=false) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({ mimeType: "application/pdf", fileName: "a.pdf" }),
        "openAI",
        makeModel({ pdfNativeDefault: false })
      )
    ).toBe("client_extract");
  });

  it("PDF → Anthropic (pdfNativeDefault=false) → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({ mimeType: "application/pdf", fileName: "a.pdf" }),
        "anthropic",
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
        "gemini",
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
        "openAI",
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
        "anthropic",
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
        "deepseek",
        makeModel({ nativeFileMimes: [] })
      )
    ).toBe("client_extract");
  });

  it("oversized file → client_extract (OOM defense)", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({ extractedSizeBytes: 40 * 1024 * 1024 }), // 40MB > 32MB OpenAI  
        "openAI",
        makeModel()
      )
    ).toBe("client_extract");
  });

  it("no originalBase64Data → client_extract", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({ originalBase64Data: undefined }),
        "openAI",
        makeModel()
      )
    ).toBe("client_extract");
  });

  it("image kind -> client_extract (images take their own image_url path)", () => {
    expect(
      decideAttachmentRoute(
        makeAttachment({ kind: "image" }),
        "openAI",
        makeModel()
      )
    ).toBe("client_extract");
  });
});

describe("maxNativeBytesFor", () => {
  it("OpenAI = 32MB", () => {
    expect(maxNativeBytesFor("openAI")).toBe(32 * 1024 * 1024);
  });
  it("Anthropic = 32MB", () => {
    expect(maxNativeBytesFor("anthropic")).toBe(32 * 1024 * 1024);
  });
  it("Gemini = 20MB (inline limit)", () => {
    expect(maxNativeBytesFor("gemini")).toBe(20 * 1024 * 1024);
  });
  it("unknown providers fall back to 32MB", () => {
    expect(maxNativeBytesFor("deepseek")).toBe(32 * 1024 * 1024);
    expect(maxNativeBytesFor("openRouter")).toBe(32 * 1024 * 1024);
  });
});
