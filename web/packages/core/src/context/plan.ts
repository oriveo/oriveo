/**
 * ContextPlan field types. The branded ContextPlan type and its only factory live in assemble.ts,
 * so nothing outside ContextAssembler.assemble can produce one.
 */

import type { Attachment } from '@oriveo/shared/pure-types';

import type { ContextManifestSegment, RequestPurpose } from './manifest';
import type { ContextRole } from './message';

export type ContextBlockKind = 'text' | 'dynamic';

export interface ContextBlock {
  kind: ContextBlockKind;
  text: string;
}

export interface ContextPlanMessage {
  id: string;
  role: ContextRole;
  blocks: ContextBlock[];
  /** Attachments kept by sanitize. */
  attachments: Attachment[];
}

export type ContextCompactionAdvice = 'none' | 'preSuggested' | 'required';

export type ContextPlanWarning = 'instructionsAndSkillOverShare';

export type ContextPlanReject = 'instructions_too_long' | 'message_too_long';

export interface ContextPlanOmitted {
  knowledge: number;
  notes: number;
  memory: number;
}

export interface ContextPlanBudget {
  W: number | null;
  B: number | null;
  oWire: number;
  /** null when the request is rejected or carries no messages. */
  estimatedInput: number | null;
}

export interface ContextPlanFields {
  purpose: RequestPurpose;
  system: string | null;
  /** null when rejected or for imageGeneration. */
  messages: ContextPlanMessage[] | null;
  segments: ContextManifestSegment[];
  omitted: ContextPlanOmitted;
  reminder: boolean;
  unansweredMerged: number;
  budget: ContextPlanBudget;
  compaction: ContextCompactionAdvice;
  warnings: ContextPlanWarning[];
  reject: ContextPlanReject | null;
  /** imageGeneration only. */
  imagePrompt: string | null;
  /** Ids of memory items actually rendered: standing instructions first, then memory, in render order. */
  memoryIds: string[];
}

export type { ContextPlan } from './assemble';
