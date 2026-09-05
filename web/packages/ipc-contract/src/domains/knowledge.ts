/**
 * Desktop IPC contract for the knowledge base. Entirely BYOK against an OpenAI vector store, and
 * a plaintext key never crosses IPC: `apiKeyRef` is the providerId, which main decrypts through
 * KeyVault.get. baseURL is the user's OpenAI-compatible endpoint. This file defines the contract
 * and the pure logic only; the main handlers, preload bridge and renderer routing live elsewhere.
 */

export interface KnowledgeRequestBase {
  /** The providerId; main decrypts it into an OpenAI key through KeyVault.get, so the plaintext never crosses IPC. */
  apiKeyRef: string;
  /** OpenAI-compatible endpoint; when empty, main uses https://api.openai.com/v1. */
  baseURL?: string;
}

export interface KnowledgeCreateVectorStoreRequest extends KnowledgeRequestBase {
  expiresAfterDays: number;
}

export interface KnowledgeUploadFileRequest extends KnowledgeRequestBase {
  /** File bytes: the renderer sends an ArrayBuffer over IPC and main wraps it in a Blob for the multipart upload. */
  fileBytes: ArrayBuffer;
  fileName: string;
  mimeType: string;
  vectorStoreId: string;
}

export interface KnowledgeUploadFileResponse {
  openAIFileId: string;
  status: 'ready' | 'failed' | 'indexing';
  sizeBytes: number;
}

export interface KnowledgeFileStatusRequest extends KnowledgeRequestBase {
  vectorStoreId: string;
  openAIFileId: string;
}

export interface KnowledgeFileStatusResponse {
  status: 'ready' | 'failed' | 'indexing' | 'error';
}

export interface KnowledgeDeleteFileRequest extends KnowledgeRequestBase {
  vectorStoreId: string;
  openAIFileId: string;
}

export interface KnowledgeDeleteVectorStoreRequest extends KnowledgeRequestBase {
  vectorStoreId: string;
}

export interface KnowledgeRetrieveRequest extends KnowledgeRequestBase {
  query: string;
  retrievalModel: string;
  vectorStoreId: string;
  maxResults?: number;
  maxSnippetChars?: number;
  maxTotalSnippetChars?: number;
}

export interface KnowledgeSnippet {
  fileId: string;
  fileName: string;
  text: string;
  score: number;
}

export interface KnowledgeRetrieveResponse {
  snippets: KnowledgeSnippet[];
  usage: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
}

export interface KnowledgeEligibilityRequest extends KnowledgeRequestBase {
  retrievalModel: string;
}

export interface KnowledgeEligibilityResponse {
  eligible: boolean;
  /** A SkillKnowledgeErrorCode: openai_not_configured / openai_endpoint_not_official / retrieval_model_not_enabled / knowledge_service_unavailable. */
  errorCode?: string;
  requiredModel?: string;
}

/**
 * The preload `window.oriveo.knowledge` bridge. Everything goes through invoke, so every call is
 * request/response rather than streaming. After upload returns, the renderer polls fileStatus
 * until it is ready or failed, matching the web behaviour.
 */
export interface OriveoKnowledgeBridge {
  createVectorStore(req: KnowledgeCreateVectorStoreRequest): Promise<string>;
  uploadFile(req: KnowledgeUploadFileRequest): Promise<KnowledgeUploadFileResponse>;
  fileStatus(req: KnowledgeFileStatusRequest): Promise<KnowledgeFileStatusResponse>;
  deleteFile(req: KnowledgeDeleteFileRequest): Promise<boolean>;
  deleteVectorStore(req: KnowledgeDeleteVectorStoreRequest): Promise<boolean>;
  retrieve(req: KnowledgeRetrieveRequest): Promise<KnowledgeRetrieveResponse>;
  /** Eligibility: use the KeyVault key to probe whether the user's OpenAI endpoint is official and the retrieval model is available, over the existing skills:knowledge:eligibility channel. */
  eligibility(req: KnowledgeEligibilityRequest): Promise<KnowledgeEligibilityResponse>;
}
