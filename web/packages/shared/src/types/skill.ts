export interface SkillTranslation {
  name: string;
  description: string;
}

export type SkillKnowledgeFileSourceType = "text" | "pdf_text";

export type SkillKnowledgeFileStatus =
  | "extracting"
  | "uploading"
  | "indexing"
  | "ready"
  | "failed"
  | "replacing"
  | "deleting"
  | "disabled";

export type SkillKnowledgeIngestionMode = "native_file" | "extracted_text";

export type SkillKnowledgeExtractedFrom = "xlsx";

export type SkillKnowledgeErrorCode =
  | "openai_not_configured"
  | "openai_endpoint_not_official"
  | "retrieval_model_not_enabled"
  | "knowledge_service_unavailable"
  | "unsupported_file_type"
  | "reference_file_too_large"
  | "knowledge_file_too_large"
  | "knowledge_total_size_exceeded"
  | "knowledge_extract_failed"
  | "knowledge_upload_failed"
  | "knowledge_index_failed"
  | "knowledge_retrieve_failed"
  | "knowledge_cleanup_failed";

export interface Skill {
  id: string;
  key?: string;
  name: string;
  description: string;
  translations?: Record<string, SkillTranslation>;
  icon: string;
  color: string;
  systemPrompt: string;
  suggestedProviderId?: string;
  suggestedModelId?: string;
  /** "any" | "reasoning" | "vision" | "fast" | "large-context" */
  modelCapabilityHint: string;
  temperature?: number;
  reasoningLevel?: string;
  webSearchEnabled?: boolean;
  starterMessages: string[];
  knowledgeFiles: SkillKnowledgeFile[];
  knowledgeBase: SkillKnowledgeBase | null;
  useMemory: boolean;
  isPinned: boolean;
  /** Pin order, updated on drag reorder */
  pinOrder: number;
  /** "builtin" | "user" | "community" */
  source: string;
  forkedFromId?: string;
  category?: string;
  /** Sort weight of a built-in skill within its category */
  sortOrder: number;
  usageCount: number;
  lastUsedAt?: string;
  createdAt: string;
  updatedAt: string;
}

export interface SkillKnowledgeFile {
  id: string;
  name: string;
  mimeType: string;
  sourceType: SkillKnowledgeFileSourceType;
  /** Plain text content; the client trims it to the context budget before sending */
  content: string;
  charCount: number;
  createdAt: string;
  updatedAt: string;
}

export interface SkillKnowledgeBase {
  provider: string;
  retrievalModel: string;
  vectorStoreId: string;
  expiresAfterDays: number;
  files: SkillKnowledgeBaseFile[];
  updatedAt: string;
}

export interface SkillKnowledgeBaseFile {
  id: string;
  name: string;
  mimeType: string;
  sizeBytes: number;
  ingestionMode: SkillKnowledgeIngestionMode;
  extractedFrom?: SkillKnowledgeExtractedFrom;
  openAIFileId?: string;
  status: SkillKnowledgeFileStatus;
  errorCode?: SkillKnowledgeErrorCode;
  createdAt: string;
  updatedAt: string;
}

export interface SkillUsage {
  count: number;
  /** null means no ceiling, which is what a local-only skill store always reports. */
  limit: number | null;
}

export interface SkillCategory {
  id: string;
  name: string;
  icon: string;
  sortOrder: number;
}
