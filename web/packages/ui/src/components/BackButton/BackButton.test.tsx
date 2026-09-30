import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { BackButton } from '../../index';

const css = `\n${readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'BackButton.module.css'), 'utf8')}`;

function ruleBody(selector: string): string {
  const marker = `\n${selector} {`;
  const start = css.indexOf(marker);
  expect(start, `BackButton.module.css has no rule for ${selector}`).toBeGreaterThanOrEqual(0);
  const bodyStart = start + marker.length;
  return css.slice(bodyStart, css.indexOf('\n}', bodyStart));
}

describe('BackButton', () => {
  afterEach(cleanup);

  it('is a labelled button that draws the shared chevron path and runs the caller action', () => {
    const onClick = vi.fn();
    render(<BackButton label="Back" onClick={onClick} />);

    const button = screen.getByRole('button', { name: 'Back' });
    expect(button.getAttribute('type')).toBe('button');

    const svg = button.querySelector('svg');
    expect(svg?.getAttribute('width')).toBe('22');
    expect(svg?.getAttribute('viewBox')).toBe('0 0 24 24');
    expect(svg?.getAttribute('stroke-width')).toBe('2.2');
    expect(svg?.getAttribute('stroke-linecap')).toBe('round');
    expect(svg?.getAttribute('aria-hidden')).toBe('true');
    expect(svg?.querySelector('path')?.getAttribute('d')).toBe('M14.5 5.5L8 12l6.5 6.5');

    fireEvent.click(button);
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it('is a flat 40px --o-text target: hover only changes colour, pressed is half opacity, RTL mirrors', () => {
    const base = ruleBody('.backButton');
    expect(base).toContain('width: 40px;');
    expect(base).toContain('height: 40px;');
    expect(base).toContain('color: var(--o-icon-button-color, var(--o-text));');
    expect(base).toContain('background: transparent;');
    expect(base).toContain('border: 0;');
    expect(base).not.toMatch(/box-shadow/);

    const hover = ruleBody('.backButton:hover');
    expect(hover.trim()).toBe('color: var(--o-icon-button-hover-color, var(--o-text-secondary));');

    expect(ruleBody('.backButton:active')).toContain('opacity: 0.5;');
    expect(ruleBody('.icon:dir(rtl)')).toContain('transform: scaleX(-1);');
  });
});
