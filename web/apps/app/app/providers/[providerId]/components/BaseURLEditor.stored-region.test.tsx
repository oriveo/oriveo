// @vitest-environment jsdom
// The trusted table only constrains the selectable options, not values the user already stored.
// After a stored mainland-China address is filtered out of the options by the trusted table, the detail page still shows it via an unfiltered reverse lookup;
// opening edit and saving without changes leaves the address byte-for-byte unchanged.
import React from 'react';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { PublicProviderConfig } from '../../../../lib/core/metadata/metadata-client';
import {
  resolveOfficialEndpointLookupOptions,
  resolveOfficialEndpointOptions,
  withStoredOfficialEndpointOption,
} from '../../../../components/providers/official-endpoint-utils';
import { BaseURLEditor } from './BaseURLEditor';

// The translate function must be stable (a fresh one each time would make dependent components re-render repeatedly).
const translate = (key: string) => key;
vi.mock('next-intl', () => ({ useTranslations: () => translate }));
vi.mock('@oriveo/ui', () => ({
  Button: ({ children, onClick }: { children: React.ReactNode; onClick?: () => void }) => (
    <button type="button" onClick={onClick}>{children}</button>
  ),
  EditIcon: () => null,
}));

const STORED_CN = 'https://api.minimaxi.com/v1';
// Decoded metadata: without trustedHosts the options contain only the international site; the original table is stored separately.
const decoded: PublicProviderConfig = {
  kind: 'miniMax',
  displayName: 'MiniMax',
  defaultBaseURL: 'https://api.minimax.io/v1',
  regionOptions: [{ id: 'global', label: 'Global', baseURL: 'https://api.minimax.io/v1' }],
  unfilteredRegionOptions: [
    { id: 'global', label: 'Global', baseURL: 'https://api.minimax.io/v1' },
    { id: 'cn', label: 'China Mainland', baseURL: 'https://api.minimaxi.com/v1/' },
  ],
};

function detailOptions(config: PublicProviderConfig | null, stored: string) {
  return withStoredOfficialEndpointOption(
    resolveOfficialEndpointOptions('miniMax', config),
    resolveOfficialEndpointLookupOptions('miniMax', config),
    stored,
  );
}

describe('A stored region is not constrained by the trusted table', () => {
  afterEach(cleanup);

  it.each([['metadata delivered', decoded], ['metadata not ready (hardcoded fallback table)', null]])(
    '%s: a stored mainland-China site still shows as cn, address unchanged',
    (_label, config) => {
      const options = detailOptions(config, STORED_CN);
      expect(options.map((option) => option.id)).toEqual(['global', 'cn']);
      expect(options.find((option) => option.id === 'cn')?.baseURL).toBe(STORED_CN);
      // Do not append when the stored value is already among the options; do not invent an option for a value outside the trusted table that cannot be reverse-looked-up.
      expect(detailOptions(config, 'https://api.minimax.io/v1').map((option) => option.id)).toEqual(['global']);
      expect(detailOptions(config, 'https://evil.example/v1').map((option) => option.id)).toEqual(['global']);
    },
  );

  it('detail page shows the stored region; opening edit and saving without changes leaves the address byte-for-byte unchanged', () => {
    const onSave = vi.fn();
    render(
      <BaseURLEditor
        currentURL={STORED_CN}
        endpointOptions={detailOptions(decoded, STORED_CN)}
        onSave={onSave}
      />,
    );
    expect(screen.getByText('China Mainland')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'editBaseURL' }));
    expect(screen.getByRole('button', { name: /China Mainland/ }).getAttribute('aria-pressed')).toBe('true');
    fireEvent.click(screen.getByRole('button', { name: 'saveBaseURL' }));
    expect(onSave).toHaveBeenCalledWith(STORED_CN);
  });
});
