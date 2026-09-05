import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { VendorIdentity } from './VendorIdentity';

vi.mock('../lib/hooks/useIsDarkTheme', () => ({
  useIsDarkTheme: () => false,
}));

vi.mock('next/image', () => ({
  default: ({ src, alt }: { src: string; alt: string }) => (
    <img src={src} alt={alt} data-testid="vendor-logo-image" />
  ),
}));

describe('VendorIdentity: managed catalog public_group_id to vendor logo', () => {
  // Every public_group_id served by the official catalog must hit VENDOR_VISUALS, otherwise the
  // badge degrades to a text monogram; gemini, grok, kimi and glm have all been missed before.
  it.each([
    ['google-gemini', '/plogos/light/gemini.png'],
    ['xai-grok', '/plogos/light/grok.png'],
    ['kimi', '/plogos/light/kimi.png'],
    ['zhipu-glm', '/plogos/light/zai.png'],
  ])('%s renders the real logo rather than a text abbreviation', (groupId, expectedSrc) => {
    render(<VendorIdentity groupId={groupId} title={groupId} />);
    const image = screen.getByTestId('vendor-logo-image');
    expect(image.getAttribute('src')).toBe(expectedSrc);
    expect(image.parentElement?.getAttribute('data-has-logo')).toBe('true');
  });

  it('falls back to a text monogram for an unknown group', () => {
    render(<VendorIdentity groupId="totally-unknown-vendor" title="Totally Unknown" />);
    expect(screen.queryByTestId('vendor-logo-image')).toBeNull();
    expect(screen.getByText('TU')).toBeTruthy();
    expect(screen.getByText('TU').parentElement?.getAttribute('data-has-logo')).toBe('false');
  });
});
