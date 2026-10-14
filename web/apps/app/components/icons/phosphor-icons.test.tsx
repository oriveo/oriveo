import { render } from '@testing-library/react';
import { Globe } from '@phosphor-icons/react';
import { PHASE_DEVELOPMENT_SERVER } from 'next/constants';
import { describe, expect, it } from 'vitest';
import { createOriveoNextConfig } from '../../next.config';

// Web Phosphor uses the official @phosphor-icons/react; duotone = the same color + a 20% base, colored via currentColor.
describe('Phosphor icons on Web', () => {
  it('renders duotone as one currentColor with a 20% underlay, no backplate', () => {
    const { container } = render(<Globe weight="duotone" size={22} color="var(--o-cap-web-search)" />);
    const svg = container.querySelector('svg');
    expect(svg?.getAttribute('fill')).toBe('var(--o-cap-web-search)');
    const underlay = [...(svg?.querySelectorAll('path') ?? [])].filter((p) => p.getAttribute('opacity') === '0.2');
    expect(underlay).toHaveLength(1);
    expect(svg?.querySelectorAll('rect, circle')).toHaveLength(0);
  });

  it('is loaded through optimizePackageImports so barrel imports stay per-icon', () => {
    const config = createOriveoNextConfig(PHASE_DEVELOPMENT_SERVER);
    expect(config.experimental?.optimizePackageImports).toContain('@phosphor-icons/react');
  });
});
