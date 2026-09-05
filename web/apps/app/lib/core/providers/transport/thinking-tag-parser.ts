/**
 * Re-exports the parser from @oriveo/core so the browser and desktop builds share one
 * implementation. Importers here keep the local path; new code can import @oriveo/core directly.
 */
export * from '@oriveo/core/providers/transport/thinking-tag-parser';
