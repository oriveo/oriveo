import type { ProbeCandidatePriority } from '../../metadata/metadata-client';

export interface ProbeAPIRootCandidate {
  rootPath: string;
  priority: ProbeCandidatePriority;
}

export interface ProbeCatalogPlanItem {
  apiRoot: string;
  priority: ProbeCandidatePriority;
}

const PRIORITY_ORDER: Record<ProbeCandidatePriority, number> = {
  default: 0,
  extended: 1,
  scenario: 2,
};

export function buildProbeCatalogPlan(input: {
  apiRootCandidates: ProbeAPIRootCandidate[];
  maxCatalogRequests: number;
}): ProbeCatalogPlanItem[] {
  if (input.maxCatalogRequests <= 0) return [];

  const deduped = new Map<string, ProbeCatalogPlanItem>();
  const sorted = [...input.apiRootCandidates].sort(
    (left, right) => PRIORITY_ORDER[left.priority] - PRIORITY_ORDER[right.priority],
  );

  for (const candidate of sorted) {
    const rootPath = candidate.rootPath.trim().replace(/\/+$/, '') || '/';
    if (!rootPath.startsWith('/') || deduped.has(rootPath)) continue;
    deduped.set(rootPath, { apiRoot: rootPath, priority: candidate.priority });
    if (deduped.size >= input.maxCatalogRequests) break;
  }

  return [...deduped.values()];
}
