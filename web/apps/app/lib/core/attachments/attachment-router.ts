import type { AIModel, Attachment } from "@oriveo/shared";
import {
  type AttachmentLine,
  attachmentTransportProfile,
  nativeFileModeOf,
} from "@oriveo/core/providers/attachment-transport";

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
 * The inputs are the outbound line plus the model: the line declaration (`attachment-transport.ts`)
 * says whether this wire accepts native files and how far, while the model's `nativeFileMimes` /
 * `pdfNativeDefault` come from metadata. The model allowlist alone is not enough: a line of the
 * same provider that has no native file block only loses the file.
 */
export type AttachmentRoute = "native" | "client_extract";

const PDF_MIME = "application/pdf";
const SCANNED_PDF = "scanned_pdf";

/**
 * Size of the original file in bytes. Derived from the raw bytes themselves rather than from
 * `extractedSizeBytes`, which can be missing (attachments whose extraction failed used to omit it,
 * so the threshold was skipped entirely).
 */
export function originalFileBytes(attachment: Attachment): number {
  const base64 = attachment.originalBase64Data;
  if (!base64) return 0;
  const padding = base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((base64.length * 3) / 4) - padding);
}

/**
 * Decides the route for one attachment.
 *
 * Order of checks; failing any precondition falls back to client_extract:
 *  1. Only file kind is handled. Images take the separate image_url path and never reach here.
 *  2. The line's native mode is not `off` (also `off` for tool legs without a native block, or a
 *     connection that already rejected file blocks). `always` and `alwaysWithTextFallback` route
 *     the same way; they differ only after the upstream rejects (see the line declaration).
 *  3. The mime must be in the model.nativeFileMimes allowlist.
 *  4. The attachment must still carry originalBase64Data (raw bytes, not truncated by the picker).
 *  5. Original byte length <= the line's declared maxNativeBytes.
 *  6. PDF: scanned_pdf -> native; model.pdfNativeDefault -> native; otherwise client_extract.
 *  7. Any other allowlisted mime (docx/xlsx/pptx/rtf/odt) -> native.
 */
export function decideAttachmentRoute(
  attachment: Attachment,
  line: AttachmentLine,
  model: AIModel
): AttachmentRoute {
  if (attachment.kind !== "file") return "client_extract";

  const mode = nativeFileModeOf(line);
  if (mode === "off") return "client_extract";

  const mime = (attachment.mimeType ?? "").toLowerCase();
  const supported = model.nativeFileMimes ?? [];
  if (!supported.includes(mime)) return "client_extract";

  if (!attachment.originalBase64Data) return "client_extract";

  if (originalFileBytes(attachment) > attachmentTransportProfile(line.transport).maxNativeBytes) {
    return "client_extract";
  }

  if (mime === PDF_MIME) {
    if (attachment.extractionErrorCode === SCANNED_PDF) return "native";
    if (model.pdfNativeDefault) return "native";
    return "client_extract";
  }

  return "native";
}
