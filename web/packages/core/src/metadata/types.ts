/**
 * Pure types for the metadata protocol.
 *
 * The metadata-client cache implementation stays in the host layer because it depends on localStorage
 * and the network, but the protocol types it publishes are zero-dependency structures consumed by core
 * modules such as the transport strategies and cost calculation, so they live here. The
 * metadata-client re-exports them so every host imports the same definitions and they cannot fork.
 */

/**
 * Field-path overrides for profile.streamShape.
 *
 * A client picks its main strategy class from `model.transport`, then uses this structure to adjust
 * field paths within a known protocol kind (Zhipu's `link` versus the standard `url`, Anthropic's
 * `cited_text` versus the standard `snippet`).
 *
 * Any missing field falls back to the strategy class's built-in default, and unrecognized fields are
 * ignored silently to keep forward compatibility.
 */
export interface StreamShape {
  /** Field path of the reasoning delta inside an SSE chunk, in dot notation. */
  reasoningDeltaPath?: string;
  /** Anthropic: the content block type that carries citations, such as "web_search_tool_result". */
  citationsBlockType?: string;
  /** Field path of the citations array, in dot notation (array indices written as `.0` / `.1`). */
  citationsArrayPath?: string;
  /** Name of the URL field inside a citation entry. Defaults to "url"; Zhipu uses "link". */
  citationUrlField?: string;
  /** Name of the title field inside a citation entry. Defaults to "title". */
  citationTitleField?: string;
  /** Name of the snippet field inside a citation entry. Defaults to "snippet"; Anthropic uses "cited_text". */
  citationSnippetField?: string;
  /** Field path of the generated image data, such as "output.images.0.url". */
  imageDataPath?: string;
}

/**
 * Per-provider transport endpoint table.
 * Endpoint changes are published through metadata, so clients do not need a new release.
 */
export interface TransportEndpoints {
  chat?: string;
  responses?: string;
  images?: string;
  embeddings?: string;
  files?: string;
}

export interface ProviderTransportDefinition {
  baseUrl: string;
  endpoints: TransportEndpoints;
  /** Provider-level request compatibility profile; when absent the client fails safe and injects nothing. */
  requestProfile?: {
    streamOptionsIncludeUsage?: boolean;
  };
}
