import type { AIModel, Attachment } from "@oriveo/shared";

/**
 * Attachment routing decision.
 *
 * A shared data model and decision function that centralizes the choice between native and
 * client_extract:
 *   - native: the raw base64 is uploaded to the provider (OpenAI input_file / Anthropic document
 *             / Gemini inlineData)
 *   - client_extract: the client extracts text first and injects it into the prompt as an
 *             ordinary text block
 *
 * The decision inputs come entirely from metadata (`model.nativeFileMimes` +
 * `model.pdfNativeDefault`), so the client hardcodes nothing about which provider is special.
 * Changing those fields through an EffectiveOverride changes routing without a client release.
 */
export type AttachmentRoute = "native" | "client_extract";

const PDF_MIME = "application/pdf";
const SCANNED_PDF = "scanned_pdf";

/**
 * Per-provider single-file size ceiling on the native path.
 * Files over the threshold are forced to client_extract, which avoids OOM and provider upload
 * failures.
 *
 * - OpenAI Responses API: 32MB (documented input_file per-file limit)
 * - Anthropic Messages: 32MB (measured document content block limit)
 * - Gemini inlineData: 20MB inline (anything larger would have to go through the File API)
 * - default: 32MB
 *
 * In the browser the per-file limit is set by ChatAttachmentPicker.maxInputFileBytes (50MB);
 * this is a further tightening that applies to the native path only.
 */
export function maxNativeBytesFor(providerKind: string): number {
  switch (providerKind) {
    case "openAI":
      return 32 * 1024 * 1024;
    case "anthropic":
      return 32 * 1024 * 1024;
    case "gemini":
      return 20 * 1024 * 1024;
    default:
      return 32 * 1024 * 1024;
  }
}

/**
 * Decides the route for one attachment.
 *
 * Order of checks; failing any precondition falls back to client_extract:
 *  1. Only file kind is handled. Images take the separate image_url path and never reach here.
 *  2. The mime must be in the model.nativeFileMimes allowlist.
 *  3. The attachment must still carry originalBase64Data (raw bytes, not truncated by the picker).
 *  4. Byte length <= maxNativeBytesFor(provider.kind).
 *  5. PDF has its own policy:
 *     - extractionErrorCode === 'scanned_pdf' -> native, for every model that supports PDF native
 *     - model.pdfNativeDefault === true -> native (all Gemini models, for example)
 *     - otherwise -> client_extract (the OpenAI / Anthropic default)
 *  6. Any other natively supported mime (docx/xlsx/pptx/rtf/odt) -> native.
 */
export function decideAttachmentRoute(
  attachment: Attachment,
  providerKind: string,
  model: AIModel
): AttachmentRoute {
  if (attachment.kind !== "file") return "client_extract";

  const mime = (attachment.mimeType ?? "").toLowerCase();
  const supported = model.nativeFileMimes ?? [];
  if (!supported.includes(mime)) return "client_extract";

  if (!attachment.originalBase64Data) return "client_extract";

  const bytes = attachment.extractedSizeBytes ?? 0;
  if (bytes > 0 && bytes > maxNativeBytesFor(providerKind)) {
    return "client_extract";
  }

  if (mime === PDF_MIME) {
    if (attachment.extractionErrorCode === SCANNED_PDF) return "native";
    if (model.pdfNativeDefault) return "native";
    return "client_extract";
  }

  return "native";
}
