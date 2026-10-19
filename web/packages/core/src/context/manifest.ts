/** Per-request context manifest and a bounded per-conversation log (context pipeline). */

import type { StopReason } from './stop-reason';

export type RequestPurpose =
  | 'chat'
  | 'continue'
  | 'toolLoopLeg'
  | 'imageGeneration'
  | 'crosscheck'
  | 'compaction'
  | 'memoryExtraction';

/** Closed set of system / context segment kinds shared by ContextPlan and ContextManifest. */
export type ContextSegmentKind =
  | 'skill'
  | 'instructions'
  | 'standingInstructions'
  | 'memory'
  | 'notes'
  | 'knowledge'
  | 'toolSafety'
  | 'purposeSystem';

export type ManifestBasis = 'observed' | 'estimated' | 'unknown';

export interface ContextManifestSegment {
  kind: ContextSegmentKind;
  tokens: number;
  items?: number;
  omitted?: number;
}

export interface ContextManifest {
  requestId: string;
  conversationId: string;
  purpose: RequestPurpose;
  transport: string;
  model: string;
  W: number | null;
  O: number;
  B: number | null;
  basis: ManifestBasis;
  estimatedInput: number;
  observedInput?: number;
  segments: ContextManifestSegment[];
  checkpointId?: string;
  tailFrom?: string;
  unansweredMerged: number;
  reminder: boolean;
  stopReason?: StopReason;
  /** Epoch milliseconds. */
  createdAt: number;
}

export const CONTEXT_MANIFEST_LOG_LIMIT = 50;

/** Keeps the newest CONTEXT_MANIFEST_LOG_LIMIT manifests per conversation, oldest first. */
export class ContextManifestLog {
  private readonly byConversation = new Map<string, ContextManifest[]>();

  append(manifest: ContextManifest): void {
    const entries = this.byConversation.get(manifest.conversationId) ?? [];
    entries.push(manifest);
    if (entries.length > CONTEXT_MANIFEST_LOG_LIMIT) {
      entries.splice(0, entries.length - CONTEXT_MANIFEST_LOG_LIMIT);
    }
    this.byConversation.set(manifest.conversationId, entries);
  }

  list(conversationId: string): ContextManifest[] {
    return [...(this.byConversation.get(conversationId) ?? [])];
  }

  latest(conversationId: string): ContextManifest | undefined {
    const entries = this.byConversation.get(conversationId);
    return entries?.[entries.length - 1];
  }
}
