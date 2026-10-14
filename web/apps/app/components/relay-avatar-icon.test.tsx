// @vitest-environment jsdom
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import {
  RELAY_AVATAR_ICONS,
  relayAvatarMarker,
  relayAvatarPickerCellMarker,
  relayAvatarPickerCells,
  relayIconSource,
  resolveRelayConnectionAvatar,
  type RelayAvatar,
} from './relay-avatar';
import {
  applyRelayAvatarPickerCell,
  getRelayAvatarChoice,
  setRelayAvatarChoice,
} from '../lib/core/providers/relay-avatar-choices';
import { ProviderIcon } from './ProviderIcon';
import { RelayDetailBoard } from '../app/providers/[providerId]/components/RelayDetailBoard';
import { relayDetailBoard } from '../app/providers/[providerId]/relay-detail-board';

/**
 * Default relay avatar icons (fixture `shared/test-fixtures/relay/relay-avatar-icon.v1.json`):
 * case ids share the same names on all platforms: RELAY-AVATAR-ICON-<caseId> / RELAY-AVATAR-PICKER-<caseId> / RELAY-AVATAR-STORE-0x / BOARD-AVATAR-PICKER-0x.
 */

interface IconFixture {
  icons: Array<{ id: string; phosphor: string; palette: string }>;
  letterChoice: string;
  cases: Array<{ id: string; providerId: string; name: string; url: string; choice?: string; expected: RelayAvatar }>;
  pickerCases: Array<{ id: string; name: string; url: string; cells: string[] }>;
}

function readFixture<T>(...segments: string[]): T {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, ...segments);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    dir = path.dirname(dir);
  }
  throw new Error(`${segments.join('/')} not found`);
}

const fixture = readFixture<IconFixture>('shared', 'test-fixtures', 'relay', 'relay-avatar-icon.v1.json');

function relayProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'relay-2',
    kind: 'relay',
    customName: 'My backup',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    baseURLText: 'https://openrouter.ai/api/v1',
    relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    ...overrides,
  } as Provider;
}

function markersIn(container: HTMLElement): string[] {
  return [...container.querySelectorAll('[data-relay-avatar]')].map((element) => element.getAttribute('data-relay-avatar')!);
}

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  cleanup();
  localStorage.clear();
});

describe('RELAY-AVATAR-ICON fixture relay-avatar-icon.v1.json', () => {
  it.each(fixture.cases.map((item) => [item.id, item] as const))('RELAY-AVATAR-ICON-%s', (_id, item) => {
    expect(resolveRelayConnectionAvatar({
      providerId: item.providerId,
      name: item.name,
      baseURL: item.url,
      choice: item.choice,
    })).toEqual(item.expected);
  });

  it('RELAY-AVATAR-ICON icon table matches the fixture entry by entry (id / phosphor / palette, in order)', () => {
    expect(RELAY_AVATAR_ICONS.map(({ id, phosphor, palette }) => ({ id, phosphor, palette }))).toEqual(fixture.icons);
  });
});

describe('RELAY-AVATAR-PICKER sheet cell order', () => {
  it.each(fixture.pickerCases.map((item) => [item.id, item] as const))('RELAY-AVATAR-PICKER-%s', (_id, item) => {
    expect(relayAvatarPickerCells({ name: item.name, baseURL: item.url }).map(relayAvatarPickerCellMarker)).toEqual(item.cells);
  });
});

describe('RELAY-AVATAR-STORE on-device choice', () => {
  it('RELAY-AVATAR-STORE-01 after picking an icon the same connection resolves to it and mounted avatars refresh right away', () => {
    const provider = relayProvider();
    const { container } = render(<ProviderIcon kind="relay" size={22} bare {...relayIconSource(provider)} />);
    expect(markersIn(container)).toEqual(['brand:openrouter']);

    act(() => { setRelayAvatarChoice(provider.id, 'butterfly'); });

    expect(getRelayAvatarChoice(provider.id)).toBe('butterfly');
    expect(markersIn(container)).toEqual(['icon:butterfly']);
    // Key = connection id: other connections are unaffected.
    expect(getRelayAvatarChoice('relay-1')).toBeUndefined();
  });

  it('RELAY-AVATAR-STORE-02 picking the brand cell removes the stored choice', () => {
    const provider = relayProvider();
    setRelayAvatarChoice(provider.id, 'flame');
    const brandCell = relayAvatarPickerCells({ name: provider.customName, baseURL: provider.baseURLText })[0];
    expect(relayAvatarPickerCellMarker(brandCell)).toBe('brand:openrouter');

    applyRelayAvatarPickerCell(provider.id, brandCell);

    expect(getRelayAvatarChoice(provider.id)).toBeUndefined();
    expect(Object.values({ ...localStorage }).join('')).not.toContain(provider.id);
    const source = relayIconSource(provider);
    expect(relayAvatarMarker(resolveRelayConnectionAvatar({
      providerId: source.providerId,
      name: source.providerName,
      baseURL: source.baseURLText,
      choice: getRelayAvatarChoice(provider.id),
    }))).toBe('brand:openrouter');
  });

  it('RELAY-AVATAR-STORE the initial cell stores "letter", an icon cell stores the icon id', () => {
    const cells = relayAvatarPickerCells({ name: 'My backup', baseURL: 'https://openrouter.ai/api/v1' });
    applyRelayAvatarPickerCell('relay-2', cells[cells.length - 1]);
    expect(getRelayAvatarChoice('relay-2')).toBe(fixture.letterChoice);
    applyRelayAvatarPickerCell('relay-2', cells[1]);
    expect(getRelayAvatarChoice('relay-2')).toBe('planet');
  });
});

describe('BOARD-AVATAR-PICKER change icon from the detail header', () => {
  function renderBoard(provider: Provider) {
    return render(
      <RelayDetailBoard
        board={relayDetailBoard(provider)}
        nameSlot={<span>{provider.customName}</span>}
        apiKeyRowLabel="editKey"
        onAction={vi.fn()}
        onDetectAgain={vi.fn()}
        isDetecting={false}
        onDelete={vi.fn()}
        disabled={false}
      />,
    );
  }

  it('BOARD-AVATAR-PICKER-01 the detail header avatar is a button that opens the Change icon sheet, cells in fixture order', () => {
    renderBoard(relayProvider());
    const button = screen.getByRole('button', { name: 'pages.relayDetail.changeIcon' });
    expect(markersIn(button)).toEqual(['brand:openrouter']);

    fireEvent.click(button);

    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByText('pages.relayDetail.changeIcon')).toBeTruthy();
    expect(within(dialog).getByRole('button', { name: 'common.done' })).toBeTruthy();
    const cells = [...dialog.querySelectorAll('[data-relay-avatar-cell]')].map((cell) => cell.getAttribute('data-relay-avatar-cell'));
    expect(cells).toEqual(fixture.pickerCases.find((item) => item.id === 'picker_with_brand')!.cells);
    // Current avatar is the brand -> the brand cell is selected.
    expect(dialog.querySelector('[data-relay-avatar-cell="brand:openrouter"]')!.getAttribute('aria-pressed')).toBe('true');
  });

  it('BOARD-AVATAR-PICKER-02 tapping a cell changes the detail header right away and stores the choice on device', () => {
    const provider = relayProvider();
    renderBoard(provider);
    fireEvent.click(screen.getByRole('button', { name: 'pages.relayDetail.changeIcon' }));
    const dialog = screen.getByRole('dialog');

    fireEvent.click(within(dialog).getByRole('button', { name: 'pages.relayDetail.avatarIcons.butterfly' }));

    expect(getRelayAvatarChoice(provider.id)).toBe('butterfly');
    expect(markersIn(screen.getByRole('button', { name: 'pages.relayDetail.changeIcon' }))).toEqual(['icon:butterfly']);
    expect(dialog.querySelector('[data-relay-avatar-cell="butterfly"]')!.getAttribute('aria-pressed')).toBe('true');

    fireEvent.click(within(dialog).getByRole('button', { name: 'pages.relayDetail.avatarLetter' }));
    expect(markersIn(screen.getByRole('button', { name: 'pages.relayDetail.changeIcon' }))).toEqual(['initial:M']);

    fireEvent.click(within(dialog).getByRole('button', { name: 'OpenRouter' }));
    expect(getRelayAvatarChoice(provider.id)).toBeUndefined();
    expect(markersIn(screen.getByRole('button', { name: 'pages.relayDetail.changeIcon' }))).toEqual(['brand:openrouter']);
  });
});
