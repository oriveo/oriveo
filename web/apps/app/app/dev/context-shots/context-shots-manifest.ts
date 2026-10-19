// The manifest shape and completeness check live in their own module: the server page imports only this, so the client hooks pulled in by the data module never reach the Server Component.
import type { MemoryKind, MemoryLayer } from '@oriveo/core/context/memory-items';
import type { CapConfirmAttempt, CapConfirmState } from '../../../lib/core/chat/context-visibility/cap-confirm';

/* -- manifest shape (the part of `oriveo.shots.context/v1` this client reads; keys starting with `$` are ignored) -- */

export interface ContextShotsModelEntry {
  id: string;
  displayName: string;
  contextLength?: number;
  maxOutputTokens?: number;
  pricing?: Record<string, unknown>;
  pricingStatus?: string;
}

export interface ContextShotsModel {
  ref: string;
  provider: string;
  entry: ContextShotsModelEntry;
}

export interface ContextShotsCheckpoint {
  kind: 'summary' | 'fallback';
  coversFrom: string;
  coversTo: string;
  summary?: string;
  createdAt: string;
}

export interface ContextShotsLedger {
  B: number | null;
  W: number | null;
  estimatedInput: number;
  observedInput?: number;
  stopReason: string;
  segments: Array<{ kind: string; tokens: number; omitted?: number }>;
}

export interface ContextShotsManifestPage {
  name: string;
  model?: string;
  messages?: 'none';
  checkpoint?: 'summary' | 'fallback';
  compactionCount?: number;
  manifest?: string;
  preferences?: { aiSummary?: boolean; defaultCap?: 'auto' | 'unlimited' | number; priceLineReminder?: boolean };
  conversationCap?: 'auto' | 'unlimited' | number | null;
  open?: 'panel' | 'picker' | 'detail' | 'conversationSettings' | 'confirm' | 'settings';
  /** Pre-send confirm input for open = confirm (context-cap-confirm.v1.json shape). */
  confirm?: {
    attempt: CapConfirmAttempt;
    estimatedInput: number;
    conversationState: CapConfirmState;
  };
  lastAssistantStopReason?: string;
  instructions?: string;
  directiveSuggestion?: { createdAt: string; userId: string; user: string; sentence: string; assistantId: string; assistant: string };
  memorySuggestion?: {
    createdAt: string;
    userId: string;
    user: string;
    assistantId: string;
    assistant: string;
    candidate: { id: string; proposedLayer: MemoryLayer; proposedKind: MemoryKind; content: string; confidence: number };
  };
}

export interface ContextShotsManifest {
  schema: 'oriveo.shots.context/v1';
  clock: string;
  models: ContextShotsModel[];
  conversation: {
    id: string;
    title: string;
    createdAt: string;
    messages: Array<{ id: string; createdAt: string; role: 'user' | 'assistant'; content: string }>;
  };
  checkpoints: Record<string, ContextShotsCheckpoint>;
  manifests: Record<string, ContextShotsLedger | string>;
  pages: ContextShotsManifestPage[];
}

/** Whether the manifest is complete (the entry refuses to open an incomplete manifest). */
export function isCompleteContextShotsManifest(value: unknown): value is ContextShotsManifest {
  if (typeof value !== 'object' || value === null) return false;
  const m = value as Partial<ContextShotsManifest>;
  return m.schema === 'oriveo.shots.context/v1'
    && typeof m.clock === 'string' && Number.isFinite(Date.parse(m.clock))
    && Array.isArray(m.models)
    && typeof m.conversation === 'object' && m.conversation !== null && Array.isArray(m.conversation.messages)
    && typeof m.checkpoints === 'object' && m.checkpoints !== null
    && typeof m.manifests === 'object' && m.manifests !== null
    && Array.isArray(m.pages);
}
