/**
 * Presentation logic for the step block. The iOS counterpart is `McpToolStepsPresentation.swift`:
 * the title, the trailing label, each row's status and detail, and the collapse rules are the same
 * on iOS, Android and web. Pure functions.
 */

import type { McpToolStep, McpToolStepStatus } from '@oriveo/shared';

export type McpStepsHeader = 'running' | 'waitingAuth' | { finished: number };

export type McpStepsTrailing =
  | { kind: 'step'; step: number }
  | { kind: 'failed'; count: number }
  | { kind: 'declined'; count: number }
  | { kind: 'servers'; names: string[] };

export type McpStepRowDetail =
  | { kind: 'args'; text: string }
  | { kind: 'declined' }
  | { kind: 'interrupted' }
  | { kind: 'authExpired'; server: string }
  | { kind: 'failure'; code: string | undefined };

export interface McpStepRow {
  step: McpToolStep;
  /** Display status: once the message is no longer generating, `running` is always drawn as `interrupted`. */
  status: McpToolStepStatus;
  detail: McpStepRowDetail;
  /** A finished step can be opened to see its details. */
  opensDetail: boolean;
}

/** With more steps than this, the earlier ones collapse into "show N earlier steps". */
export const MCP_STEPS_COLLAPSE_THRESHOLD = 5;
/** How many trailing steps stay visible when collapsed. */
export const MCP_STEPS_TAIL_WHEN_COLLAPSED = 2;

export interface McpStepsPresentation {
  header: McpStepsHeader;
  trailing: McpStepsTrailing;
  rows: McpStepRow[];
  /** Running or waiting for authorization: expanded by default. */
  isActive: boolean;
  /** The step waiting for re-authorization (the block offers "re-authorize" and "skip this step"). */
  pausedStep: McpToolStep | null;
  limitReached: boolean;
  /** Number of rows hidden when earlier steps are collapsed; 0 when nothing needs collapsing. */
  hiddenEarlierCount: number;
}

function detailFor(step: McpToolStep, status: McpToolStepStatus): McpStepRowDetail {
  switch (status) {
    case 'running':
    case 'done':
      return { kind: 'args', text: step.argsSummary };
    case 'denied':
      return { kind: 'declined' };
    case 'interrupted':
      return { kind: 'interrupted' };
    case 'needsAuth':
      return { kind: 'authExpired', server: step.serverName };
    case 'failed':
      return { kind: 'failure', code: step.errorCode };
  }
}

export function buildMcpStepsPresentation(input: {
  steps: readonly McpToolStep[];
  isGenerating: boolean;
  limitReached?: boolean;
  pausedStepId?: string | null;
}): McpStepsPresentation {
  const rows = input.steps.map((step): McpStepRow => {
    const status: McpToolStepStatus = step.status === 'running' && !input.isGenerating ? 'interrupted' : step.status;
    return { step, status, detail: detailFor(step, status), opensDetail: status !== 'running' };
  });
  const paused = input.isGenerating && input.pausedStepId ? input.steps.find((step) => step.id === input.pausedStepId) ?? null : null;
  const running = [...rows].reverse().find((row) => row.status === 'running');
  const latestStep = rows.reduce((max, row) => Math.max(max, row.step.step), 0);

  let header: McpStepsHeader;
  let trailing: McpStepsTrailing;
  if (paused) {
    header = 'waitingAuth';
    trailing = { kind: 'step', step: paused.step };
  } else if (running) {
    header = 'running';
    trailing = { kind: 'step', step: running.step.step };
  } else if (input.isGenerating) {
    // Between two steps (the model is deciding what to do next): still in progress, reusing the latest step number.
    header = 'running';
    trailing = { kind: 'step', step: latestStep };
  } else {
    header = { finished: rows.filter((row) => row.status === 'done').length };
    const failed = rows.filter((row) => row.status === 'failed' || row.status === 'needsAuth').length;
    const declined = rows.filter((row) => row.status === 'denied').length;
    if (failed > 0) trailing = { kind: 'failed', count: failed };
    else if (declined > 0) trailing = { kind: 'declined', count: declined };
    else {
      const names: string[] = [];
      for (const step of input.steps) if (step.serverName && !names.includes(step.serverName)) names.push(step.serverName);
      trailing = { kind: 'servers', names };
    }
  }
  return {
    header,
    trailing,
    rows,
    isActive: input.isGenerating,
    pausedStep: paused,
    limitReached: Boolean(input.limitReached) && !input.isGenerating,
    hiddenEarlierCount: rows.length > MCP_STEPS_COLLAPSE_THRESHOLD ? rows.length - MCP_STEPS_TAIL_WHEN_COLLAPSED : 0,
  };
}

/** Message key (`mcp.chat.steps.*`) for a failure: chosen only by the closed set of error codes, never carrying the server's raw text. */
export function mcpStepFailureKey(code: string | undefined): 'stepTimeout' | 'stepUnreachable' | 'stepTooLarge' | 'stepUnavailable' | 'stepSkipped' | 'stepFailed' {
  switch (code) {
    case 'timeout':
      return 'stepTimeout';
    case 'unreachable':
      return 'stepUnreachable';
    case 'result_too_large':
      return 'stepTooLarge';
    case 'tool_unavailable':
      return 'stepUnavailable';
    case 'auth_skipped':
      return 'stepSkipped';
    default:
      return 'stepFailed';
  }
}
