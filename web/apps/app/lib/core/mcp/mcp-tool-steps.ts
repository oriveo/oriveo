/**
 * MCP tool steps on a message. The iOS counterpart is `McpToolStep.swift`.
 *
 * A message holds only summaries. Raw arguments and results are per-step payloads kept in their
 * own store (stepPayloads in `mcp-idb.ts`). This file is pure functions: executor callback to
 * summary, merging, and turning unfinished steps into "interrupted" on reload.
 */

import type { McpToolStep } from '@oriveo/shared';
import type { McpToolStepUpdate } from '@oriveo/core/mcp/index';

export const MCP_TOOL_STEP_SCOPE = 'mcp';

/** One status callback from the executor, turned into the summary kept on the message. Payload, permission and the read-only hint are left out. */
export function mcpToolStepFromUpdate(update: McpToolStepUpdate): McpToolStep {
  return {
    id: update.id,
    scope: MCP_TOOL_STEP_SCOPE,
    serverId: update.serverId.toLowerCase(),
    serverName: update.serverName,
    toolName: update.toolName,
    title: update.title,
    argsSummary: update.argsSummary,
    status: update.status,
    ...(update.errorCode ? { errorCode: update.errorCode } : {}),
    step: update.step,
    ...(update.durationMs != null ? { durationMs: update.durationMs } : {}),
  };
}

/** Merges one callback into the existing steps: replace on a matching id, append otherwise. */
export function mergeMcpToolStep(steps: readonly McpToolStep[] | undefined, update: McpToolStepUpdate): McpToolStep[] {
  const step = mcpToolStepFromUpdate(update);
  const result = [...(steps ?? [])];
  const index = result.findIndex((item) => item.id === step.id);
  if (index >= 0) result[index] = step;
  else result.push(step);
  return result;
}

/**
 * Turns steps still marked `running` into `interrupted`: once the page was closed or the process
 * was killed, nothing will ever move them to a terminal state. Returns the original array when no step needs changing (same reference, which callers
 * use to decide whether to write back).
 */
export function interruptRunningMcpToolSteps<T extends readonly McpToolStep[] | undefined>(steps: T): T {
  if (!steps || !steps.some((step) => step.status === 'running')) return steps;
  return steps.map((step) => (step.status === 'running' ? { ...step, status: 'interrupted' as const, errorCode: 'interrupted' } : step)) as unknown as T;
}

/** Display title: falls back to the raw tool name when the server gave no title. */
export function mcpToolStepDisplayTitle(step: Pick<McpToolStep, 'title' | 'toolName'>): string {
  return step.title || step.toolName;
}
