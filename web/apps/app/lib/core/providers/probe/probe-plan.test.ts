import { describe, expect, it } from 'vitest';
import { buildProbeCatalogPlan } from './probe-plan';

describe('buildProbeCatalogPlan', () => {
  it('truncates catalog requests in layer order, honouring maxCatalogRequests', () => {
    const plan = buildProbeCatalogPlan({
      apiRootCandidates: [
        { rootPath: '/v1', priority: 'default' },
        { rootPath: '/v1beta', priority: 'default' },
        { rootPath: '/openai/v1', priority: 'extended' },
        { rootPath: '/anthropic/v1', priority: 'extended' },
      ],
      maxCatalogRequests: 3,
    });

    expect(plan.map((item) => item.apiRoot)).toEqual(['/v1', '/v1beta', '/openai/v1']);
  });
});
