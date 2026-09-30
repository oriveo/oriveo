import type { CSSProperties } from 'react';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';

import { CloseButton } from '../../index';

describe('CloseButton', () => {
  afterEach(cleanup);

  it('is a flat labelled button that draws the shared cross path and runs the caller action', () => {
    const onClick = vi.fn();
    render(<CloseButton label="Close" onClick={onClick} style={{ '--o-icon-button-color': 'red' } as CSSProperties} />);

    const button = screen.getByRole('button', { name: 'Close' });
    expect(button.getAttribute('type')).toBe('button');
    expect(button.className).toContain('backButton');
    expect(button.style.getPropertyValue('--o-icon-button-color')).toBe('red');

    const svg = button.querySelector('svg');
    expect(svg?.getAttribute('width')).toBe('22');
    expect(svg?.getAttribute('stroke-width')).toBe('2');
    expect(svg?.querySelector('path')?.getAttribute('d')).toBe('M7 7l10 10M17 7L7 17');

    fireEvent.click(button);
    expect(onClick).toHaveBeenCalledTimes(1);
  });
});
