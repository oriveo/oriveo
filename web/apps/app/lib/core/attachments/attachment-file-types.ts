/**
 * Attachment type detection (attachment extraction output spec section 2): the single list shared by entry checks (picker filter, drag and drop, paste) and the extractors.
 *
 * The list matches the shared fixture `shared/test-fixtures/attachments/extraction/supported-types.v1.json` entry by entry,
 * locked by extraction-golden.contract.test.ts; changing it here requires changing the fixture and spec in the same round.
 * Videos and images are routed before type detection and are not handled here.
 */

export type AttachmentFileKind =
  | 'legacy'
  | 'pdf'
  | 'epub'
  | 'html'
  | 'rtf'
  | 'docx'
  | 'xlsx'
  | 'pptx'
  | 'odt'
  | 'ods'
  | 'odp'
  | 'text'
  | 'unsupported';

interface TypeEntry {
  extensions: readonly string[];
  mimes: readonly string[];
  /** Text category only: list of whole filenames with no extension. */
  filenames?: readonly string[];
  /** Text category only: any `text/*` outside the list also belongs to this category. */
  anyTextMime?: boolean;
}

/** Ordered as in the spec section 2 table: when matching by mime, the first matching category wins (the text `text/*` fallback goes last). */
export const SUPPORTED_ATTACHMENT_TYPES = {
  legacy: {
    extensions: ['doc', 'xls', 'ppt', 'pages', 'numbers', 'key'],
    mimes: [
      'application/msword', 'application/vnd.ms-excel', 'application/vnd.ms-powerpoint',
      'application/vnd.apple.pages', 'application/vnd.apple.numbers', 'application/vnd.apple.keynote',
    ],
  },
  pdf: { extensions: ['pdf'], mimes: ['application/pdf'] },
  epub: { extensions: ['epub'], mimes: ['application/epub+zip'] },
  html: { extensions: ['html', 'htm', 'xhtml'], mimes: ['text/html', 'application/xhtml+xml'] },
  rtf: { extensions: ['rtf'], mimes: ['application/rtf', 'text/rtf'] },
  docx: { extensions: ['docx'], mimes: ['application/vnd.openxmlformats-officedocument.wordprocessingml.document'] },
  xlsx: { extensions: ['xlsx'], mimes: ['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'] },
  pptx: { extensions: ['pptx'], mimes: ['application/vnd.openxmlformats-officedocument.presentationml.presentation'] },
  odt: { extensions: ['odt'], mimes: ['application/vnd.oasis.opendocument.text'] },
  ods: { extensions: ['ods'], mimes: ['application/vnd.oasis.opendocument.spreadsheet'] },
  odp: { extensions: ['odp'], mimes: ['application/vnd.oasis.opendocument.presentation'] },
  text: {
    extensions: [
      'txt', 'text', 'md', 'markdown', 'mdx', 'rst', 'adoc', 'asciidoc', 'org', 'tex', 'bib', 'srt', 'vtt',
      'json', 'jsonl', 'ndjson', 'geojson', 'ipynb', 'csv', 'tsv', 'xml', 'svg', 'yaml', 'yml', 'toml', 'ini',
      'cfg', 'conf', 'properties', 'env', 'log', 'diff', 'patch', 'gitignore', 'editorconfig',
      'py', 'pyi', 'js', 'jsx', 'ts', 'tsx', 'mjs', 'cjs', 'vue', 'svelte', 'astro',
      'go', 'rs', 'java', 'kt', 'kts', 'scala', 'groovy', 'gradle', 'swift', 'm', 'mm',
      'c', 'h', 'cpp', 'hpp', 'cc', 'cs', 'fs', 'vb', 'rb', 'php', 'pl', 'pm', 'lua', 'dart', 'r', 'jl',
      'hs', 'ml', 'ex', 'exs', 'erl', 'clj', 'zig', 'nim',
      'sh', 'bash', 'zsh', 'fish', 'ps1', 'bat', 'cmd', 'sql', 'graphql', 'proto',
      'css', 'scss', 'sass', 'less', 'tf', 'hcl', 'cmake',
    ],
    filenames: ['dockerfile', 'makefile', 'license', 'readme', 'gitignore', 'editorconfig'],
    mimes: [
      'text/plain', 'text/markdown', 'text/csv', 'text/tab-separated-values', 'text/xml', 'text/css',
      'text/javascript', 'text/x-yaml', 'text/x-toml', 'text/x-ini', 'text/x-python', 'text/x-go',
      'application/json', 'application/xml', 'application/x-yaml', 'application/javascript',
      'application/typescript', 'application/x-sh', 'image/svg+xml',
    ],
    /** Any `text/*` outside the list (except those categorized above) is also treated as plain text. */
    anyTextMime: true,
  },
} as const satisfies Record<Exclude<AttachmentFileKind, 'unsupported'>, TypeEntry>;

type KnownKind = keyof typeof SUPPORTED_ATTACHMENT_TYPES;
const KIND_ORDER = Object.keys(SUPPORTED_ATTACHMENT_TYPES) as KnownKind[];

const KIND_BY_EXTENSION = new Map<string, KnownKind>();
const KIND_BY_MIME = new Map<string, KnownKind>();
for (const kind of KIND_ORDER) {
  const entry: TypeEntry = SUPPORTED_ATTACHMENT_TYPES[kind];
  for (const ext of entry.extensions) if (!KIND_BY_EXTENSION.has(ext)) KIND_BY_EXTENSION.set(ext, kind);
  for (const mime of entry.mimes) if (!KIND_BY_MIME.has(mime)) KIND_BY_MIME.set(mime, kind);
}
const TEXT_FILENAMES = new Set<string>(SUPPORTED_ATTACHMENT_TYPES.text.filenames);
const TEXT_EXTENSIONS = new Set<string>(SUPPORTED_ATTACHMENT_TYPES.text.extensions);

/** Categories that go through the Office parser (OOXML, ODF, RTF). */
export const OFFICE_FILE_KINDS: ReadonlySet<AttachmentFileKind> = new Set(['docx', 'xlsx', 'pptx', 'odt', 'ods', 'odp', 'rtf']);
/** The three OOXML categories: check for an OLE compound document header before opening the zip (spec section 16). */
export const OOXML_FILE_KINDS: ReadonlySet<AttachmentFileKind> = new Set(['docx', 'xlsx', 'pptx']);

/**
 * Spec section 2: if the extension is recognized, it decides the category; mime is consulted only when the extension is unknown or empty.
 * For filenames with no `.`, or starting with `.` and containing only that one `.`, the whole filename (minus the leading `.`) is compared first against
 * the `filenames` list, then against the text extension list.
 */
export function classifyAttachmentFile(fileName: string, mime: string | null | undefined): AttachmentFileKind {
  const lower = fileName.toLowerCase();
  const dot = lower.lastIndexOf('.');
  let ext = '';
  if (dot === -1 || (dot === 0 && lower.indexOf('.', 1) === -1)) {
    const bare = dot === 0 ? lower.slice(1) : lower;
    if (TEXT_FILENAMES.has(bare) || TEXT_EXTENSIONS.has(bare)) return 'text';
  } else {
    ext = lower.slice(dot + 1);
  }
  const byExtension = ext ? KIND_BY_EXTENSION.get(ext) : undefined;
  if (byExtension) return byExtension;

  const normalizedMime = (mime ?? '').split(';')[0].trim().toLowerCase();
  if (!normalizedMime) return 'unsupported';
  const byMime = KIND_BY_MIME.get(normalizedMime);
  if (byMime) return byMime;
  if (SUPPORTED_ATTACHMENT_TYPES.text.anyTextMime && normalizedMime.startsWith('text/')) return 'text';
  return 'unsupported';
}

/**
 * Extension list for the file picker `accept` (`.ext` joined by commas), taken from the same list.
 * Legacy formats are listed too: they must be selectable so the "save as a new format" hint can show; the entry blocks them from the input box.
 * Whether PDF is included is decided by the caller based on provider capability.
 */
export function attachmentAcceptExtensions({ includePdf }: { includePdf: boolean }): string {
  return KIND_ORDER
    .filter((kind) => includePdf || kind !== 'pdf')
    .flatMap((kind) => SUPPORTED_ATTACHMENT_TYPES[kind].extensions.map((ext) => `.${ext}`))
    .join(',');
}
