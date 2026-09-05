/**
 * Provider-agnostic shared types live in @oriveo/core, so the web and desktop builds import
 * one definition. This module re-exports them under the existing path.
 */
export type {
  StreamUsage,
  StreamEvent,
  StreamHandle,
  SyncResult,
  ContentPart,
  StreamOptions,
} from '@oriveo/core';
