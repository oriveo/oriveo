// Type declarations for metadata-payload-validators.generated.js (hand-written; keep in step with the export names of the generator script).

export interface MetadataPayloadValidationError {
  instancePath: string;
  schemaPath: string;
  keyword: string;
  params: Record<string, unknown>;
  message?: string;
}

export interface MetadataPayloadValidator {
  (data: unknown): boolean;
  errors?: MetadataPayloadValidationError[] | null;
}

export declare const fullOrIndex: MetadataPayloadValidator;
export declare const catalog: MetadataPayloadValidator;
export declare const provider: MetadataPayloadValidator;
export declare const model: MetadataPayloadValidator;
