import type {
  SkillKnowledgeBase,
  SkillKnowledgeBaseFile,
  SkillKnowledgeErrorCode,
  SkillKnowledgeExtractedFrom,
  SkillKnowledgeIngestionMode,
} from '@oriveo/shared';

/**
 * Pure build logic for SkillKnowledgeBase, the single source shared by the Next route (_shared.ts)
 * and the desktop renderer branch. Pure functions over crypto.randomUUID and Date, both available
 * in browsers and Node, with no IO.
 */

export function buildKnowledgeBase(params: {
  existingKnowledgeBase: SkillKnowledgeBase | null;
  provider: string;
  retrievalModel: string;
  vectorStoreId: string;
  expiresAfterDays: number;
  file: SkillKnowledgeBaseFile;
}): SkillKnowledgeBase {
  const files = params.existingKnowledgeBase
    ? [...params.existingKnowledgeBase.files, params.file]
    : [params.file];

  return {
    provider: params.provider,
    retrievalModel: params.retrievalModel,
    vectorStoreId: params.vectorStoreId,
    expiresAfterDays: params.expiresAfterDays,
    files,
    updatedAt: new Date().toISOString(),
  };
}

export function buildKnowledgeBaseFile(params: {
  id?: string;
  fileName: string;
  mimeType: string;
  sizeBytes: number;
  ingestionMode: SkillKnowledgeIngestionMode;
  extractedFrom?: SkillKnowledgeExtractedFrom;
  openAIFileId?: string;
  status: SkillKnowledgeBaseFile['status'];
  errorCode?: SkillKnowledgeErrorCode;
  createdAt?: string;
}): SkillKnowledgeBaseFile {
  const now = new Date().toISOString();
  return {
    id: params.id ?? crypto.randomUUID(),
    name: params.fileName,
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

export function replaceKnowledgeBaseFile(params: {
  knowledgeBase: SkillKnowledgeBase | null;
  provider: string;
  retrievalModel: string;
  vectorStoreId: string;
  expiresAfterDays: number;
  file: SkillKnowledgeBaseFile;
  targetFileId?: string;
}): SkillKnowledgeBase {
  const files = [...(params.knowledgeBase?.files ?? [])];
  const replaceIndex = files.findIndex((entry) => entry.id === (params.targetFileId ?? params.file.id));

  if (replaceIndex >= 0) {
    files[replaceIndex] = params.file;
  } else {
    files.push(params.file);
  }

  return {
    provider: params.provider,
    retrievalModel: params.retrievalModel,
    vectorStoreId: params.vectorStoreId,
    expiresAfterDays: params.expiresAfterDays,
    files,
    updatedAt: new Date().toISOString(),
  };
}

export function removeKnowledgeBaseFile(params: {
  knowledgeBase: SkillKnowledgeBase;
  targetFileId: string;
}): SkillKnowledgeBase | null {
  const files = params.knowledgeBase.files.filter((file) => file.id !== params.targetFileId);
  if (files.length === 0) {
    return null;
  }
  return {
    ...params.knowledgeBase,
    files,
    updatedAt: new Date().toISOString(),
  };
}
