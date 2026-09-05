import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';

const push = vi.fn();
vi.mock('next/navigation', () => ({ useRouter: () => ({ push }) }));
vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));
vi.mock('@oriveo/ui', () => ({
  Button: (props: { children: unknown; onClick?: () => void }) => (
    <button type="button" onClick={props.onClick}>{props.children as string}</button>
  ),
}));

const providersState: { providers: Array<{ id: string; kind: string }> } = { providers: [] };
vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (sel: (s: typeof providersState) => unknown) => sel(providersState),
}));
vi.mock('./RelayDetail', () => ({ RelayDetail: () => <div>relay-detail</div> }));
vi.mock('./OfficialProviderDetail', () => ({ OfficialProviderDetail: () => <div>official-detail</div> }));

import { ProviderDetailRouter } from './ProviderDetailRouter';

describe('ProviderDetailRouter', () => {
  it('renders official detail for BYOK providers', () => {
    providersState.providers = [{ id: 'openai', kind: 'openai' }];
    render(<ProviderDetailRouter providerId="openai" />);
    expect(screen.getByText('official-detail')).toBeTruthy();
  });

});
