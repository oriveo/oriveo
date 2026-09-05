import type {
  SkillKnowledgeBase,
  SkillKnowledgeBaseFile,
  SkillKnowledgeErrorCode,
  SkillKnowledgeExtractedFrom,
  SkillKnowledgeFile,
  SkillKnowledgeFileSourceType,
  SkillKnowledgeIngestionMode,
} from '@oriveo/shared';
import { parseOfficeFile } from '../../../lib/utils/office-parser';

export const MAX_REFERENCE_FILE_SIZE = 3 * 1024 * 1024;
export const MAX_KNOWLEDGE_FILE_SIZE = 20 * 1024 * 1024;
export const MAX_KNOWLEDGE_FILES = 5;
export const MAX_KNOWLEDGE_TOTAL_BYTES = 100 * 1024 * 1024;
export const MAX_FILE_NAME_LENGTH = 120;
const TEXT_FILE_EXTENSIONS = new Set([
  'txt', 'md', 'json', 'csv', 'html', 'xml', 'yaml', 'yml',
  'css', 'js', 'ts', 'jsx', 'tsx', 'py', 'java', 'kt', 'swift', 'go', 'sql',
]);

export function codePointCount(str: string): number {
  return [...str].length;
}

export function sanitizeSkillFileName(name: string, maxLength = MAX_FILE_NAME_LENGTH): string {
  const cleaned = name
    .replace(/[\u0000-\u001F\u007F]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  if (!cleaned) {
    return 'file';
  }
  if (cleaned.length <= maxLength) {
    return cleaned;
  }

  const extIndex = cleaned.lastIndexOf('.');
  if (extIndex <= 0 || extIndex === cleaned.length - 1) {
    return cleaned.slice(0, maxLength).trim();
  }

  const ext = cleaned.slice(extIndex);
  const base = cleaned.slice(0, extIndex);
  const clippedBase = base.slice(0, Math.max(1, maxLength - ext.length)).trim();
  return `${clippedBase}${ext}`.slice(0, maxLength);
}

export function validateReferenceFileSize(sizeBytes: number): SkillKnowledgeErrorCode | null {
  return sizeBytes > MAX_REFERENCE_FILE_SIZE ? 'reference_file_too_large' : null;
}

export function validateKnowledgeBaseQuota(params: {
  existingCount: number;
  existingBytes: number;
  nextFileBytes: number;
}): SkillKnowledgeErrorCode | null {
  if (params.existingCount >= MAX_KNOWLEDGE_FILES) {
    return 'knowledge_total_size_exceeded';
  }
  if (params.nextFileBytes > MAX_KNOWLEDGE_FILE_SIZE) {
    return 'knowledge_file_too_large';
  }
  if (params.existingBytes + params.nextFileBytes > MAX_KNOWLEDGE_TOTAL_BYTES) {
    return 'knowledge_total_size_exceeded';
  }
  return null;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function isKnowledgeFileTypeSupported(file: File, supportedFileTypes: string[]): boolean {
  const ext = file.name.toLowerCase().split('.').pop() ?? '';
  if (supportedFileTypes.includes(ext)) {
    return true;
  }
  if (supportedFileTypes.includes('txt')) {
    return file.type.startsWith('text/') || TEXT_FILE_EXTENSIONS.has(ext);
  }
  return false;
}

export function sumKnowledgeBaseBytes(knowledgeBase: SkillKnowledgeBase | null): number {
  return (knowledgeBase?.files ?? []).reduce((sum, file) => sum + file.sizeBytes, 0);
}

export function buildReferenceKnowledgeFile(params: {
  id: string;
  name: string;
  mimeType: string;
  sourceType: SkillKnowledgeFileSourceType;
  content: string;
  now?: string;
}): SkillKnowledgeFile {
  const now = params.now ?? new Date().toISOString();
  return {
    id: params.id,
    name: sanitizeSkillFileName(params.name),
    mimeType: params.mimeType,
    sourceType: params.sourceType,
    content: params.content,
    charCount: codePointCount(params.content),
    createdAt: now,
    updatedAt: now,
  };
}

export function buildLocalKnowledgeBaseFile(params: {
  id: string;
  name: string;
  mimeType: string;
  sizeBytes: number;
  ingestionMode: SkillKnowledgeIngestionMode;
  extractedFrom?: SkillKnowledgeExtractedFrom;
  status: SkillKnowledgeBaseFile['status'];
  errorCode?: SkillKnowledgeErrorCode;
  openAIFileId?: string;
  createdAt?: string;
}): SkillKnowledgeBaseFile {
  const now = new Date().toISOString();
  return {
    id: params.id,
    name: sanitizeSkillFileName(params.name),
    mimeType: params.mimeType,
    sizeBytes: params.sizeBytes,
    ingestionMode: params.ingestionMode,
    ...(params.extractedFrom ? { extractedFrom: params.extractedFrom } : {}),
    ...(params.openAIFileId ? { openAIFileId: params.openAIFileId } : {}),
    status: params.status,
    ...(params.errorCode ? { errorCode: params.errorCode } : {}),
    createdAt: params.createdAt ?? now,
    updatedAt: now,
  };
}

export function upsertLocalKnowledgeBase(params: {
  knowledgeBase: SkillKnowledgeBase | null;
  provider: string;
  retrievalModel: string;
  expiresAfterDays: number;
  file: SkillKnowledgeBaseFile;
  vectorStoreId?: string;
}): SkillKnowledgeBase {
  const files = [...(params.knowledgeBase?.files ?? [])];
  const index = files.findIndex((entry) => entry.id === params.file.id);
  if (index >= 0) {
    files[index] = params.file;
  } else {
    files.push(params.file);
  }

  return {
    provider: params.provider,
    retrievalModel: params.retrievalModel,
    vectorStoreId: params.vectorStoreId ?? params.knowledgeBase?.vectorStoreId ?? '',
    expiresAfterDays: params.expiresAfterDays,
    files,
    updatedAt: new Date().toISOString(),
  };
}

/** After a successful upload, move files in the indexing state straight to ready, since OpenAI finishes indexing in the background. */
export function removeLocalKnowledgeBaseFile(
  knowledgeBase: SkillKnowledgeBase | null,
  targetFileId: string,
): SkillKnowledgeBase | null {
  if (!knowledgeBase) return null;
  const files = knowledgeBase.files.filter((file) => file.id !== targetFileId);
  if (files.length === 0) return null;
  return {
    ...knowledgeBase,
    files,
    updatedAt: new Date().toISOString(),
  };
}

export interface DraftKnowledgeCleanupPlan {
  vectorStoreId: string;
  deleteVectorStore: boolean;
  openAIFileIds: string[];
}

function collectOpenAIFileIds(knowledgeBase: SkillKnowledgeBase | null): Set<string> {
  return new Set(
    (knowledgeBase?.files ?? [])
      .map((file) => file.openAIFileId?.trim())
      .filter((value): value is string => Boolean(value)),
  );
}

export function buildDraftKnowledgeCleanupPlan(params: {
  originalKnowledgeBase: SkillKnowledgeBase | null;
  currentKnowledgeBase: SkillKnowledgeBase | null;
}): DraftKnowledgeCleanupPlan | null {
  const currentKnowledgeBase = params.currentKnowledgeBase;
  if (!currentKnowledgeBase) {
    return null;
  }

  const originalOpenAIFileIds = collectOpenAIFileIds(params.originalKnowledgeBase);
  const openAIFileIds = currentKnowledgeBase.files
    .map((file) => file.openAIFileId?.trim())
    .filter((value): value is string => typeof value === 'string' && value.length > 0)
    .filter((value) => !originalOpenAIFileIds.has(value));

  if (openAIFileIds.length === 0) {
    return null;
  }

  return {
    vectorStoreId: currentKnowledgeBase.vectorStoreId,
    deleteVectorStore: !params.originalKnowledgeBase
      && currentKnowledgeBase.vectorStoreId.trim().length > 0,
    openAIFileIds,
  };
}

export function requiresRemoteKnowledgeCleanup(params: {
  originalKnowledgeBase: SkillKnowledgeBase | null;
  currentKnowledgeBase: SkillKnowledgeBase | null;
}): boolean {
  const originalKnowledgeBase = params.originalKnowledgeBase;
  if (!originalKnowledgeBase) {
    return false;
  }

  const currentOpenAIFileIds = collectOpenAIFileIds(params.currentKnowledgeBase);
  const previousOpenAIFileIds = [...collectOpenAIFileIds(originalKnowledgeBase)];
  if (previousOpenAIFileIds.some((openAIFileId) => !currentOpenAIFileIds.has(openAIFileId))) {
    return true;
  }

  const currentVectorStoreId = params.currentKnowledgeBase?.vectorStoreId.trim() ?? '';
  return originalKnowledgeBase.vectorStoreId.trim().length > 0
    && originalKnowledgeBase.vectorStoreId.trim() !== currentVectorStoreId;
}

export interface PreparedKnowledgeUpload {
  displayName: string;
  displayMimeType: string;
  displaySizeBytes: number;
  uploadFile: File;
  ingestionMode: SkillKnowledgeIngestionMode;
  extractedFrom?: SkillKnowledgeExtractedFrom;
}

function replaceExtension(fileName: string, nextExt: string): string {
  const dotIndex = fileName.lastIndexOf('.');
  if (dotIndex <= 0) {
    return `${fileName}${nextExt}`;
  }
  return `${fileName.slice(0, dotIndex)}${nextExt}`;
}

async function maybeRenameFile(file: File, nextName: string): Promise<File> {
  if (file.name === nextName) {
    return file;
  }
  return new File([await file.arrayBuffer()], nextName, {
    type: file.type || 'application/octet-stream',
  });
}

export async function prepareKnowledgeUpload(
  file: File,
  parseOfficeText: typeof parseOfficeFile = parseOfficeFile,
): Promise<PreparedKnowledgeUpload> {
  const displayName = sanitizeSkillFileName(file.name);
  const displayMimeType = file.type || 'application/octet-stream';
  const lowerName = displayName.toLowerCase();

  if (lowerName.endsWith('.xlsx')) {
    const text = (await parseOfficeText(file)).trim();
    if (!text) {
      throw new Error('knowledge_extract_failed');
    }
    return {
      displayName,
      displayMimeType,
      displaySizeBytes: file.size,
      uploadFile: new File([text], replaceExtension(displayName, '.txt'), {
        type: 'text/plain',
      }),
      ingestionMode: 'extracted_text',
      extractedFrom: 'xlsx',
    };
  }

  return {
    displayName,
    displayMimeType,
    displaySizeBytes: file.size,
    uploadFile: await maybeRenameFile(file, displayName),
    ingestionMode: 'native_file',
  };
}
