import { renderHook } from '@testing-library/react';
import { NextIntlClientProvider } from 'next-intl';
import type { ReactNode } from 'react';
import { describe, expect, it, vi } from 'vitest';
import type { Skill, SkillCategory } from '@oriveo/shared';
import { useSkillL10n } from './useSkillL10n';

// The global setup mocks next-intl; this test needs the real missing-message behaviour.
vi.unmock('next-intl');

// next-intl does not throw on a missing key: it logs and returns the key path, so a
// try/catch fallback never fires. Server-defined categories / builtins without a local
// entry must show the server-provided text, not "builtinSkills.category.<id>".
const messages = {
  builtinSkills: {
    category: { coding: 'Coding' },
    code_assistant: { name: 'Code Assistant', description: 'Programming help', starters: ['Fix this bug'] },
  },
};

function wrapper({ children }: { children: ReactNode }) {
  return (
    <NextIntlClientProvider locale="en" messages={messages} onError={vi.fn()}>
      {children}
    </NextIntlClientProvider>
  );
}

const builtin = (key: string): Skill =>
  ({ source: 'builtin', key, name: 'Server name', description: 'Server description', starterMessages: ['Server starter'] }) as unknown as Skill;

describe('useSkillL10n', () => {
  it('unknown_category_falls_back_to_server_name', () => {
    const { result } = renderHook(() => useSkillL10n(), { wrapper });
    expect(result.current.localizedCategoryName({ id: 'productivity', name: 'Productivity' } as SkillCategory)).toBe('Productivity');
    expect(result.current.localizedCategoryName({ id: 'coding', name: 'Code' } as SkillCategory)).toBe('Coding');
  });

  it('unknown_builtin_key_falls_back_to_server_text', () => {
    const { result } = renderHook(() => useSkillL10n(), { wrapper });
    const unknown = builtin('not_shipped_locally');
    expect(result.current.localizedName(unknown)).toBe('Server name');
    expect(result.current.localizedDescription(unknown)).toBe('Server description');
    expect(result.current.localizedStarterMessages(unknown)).toEqual(['Server starter']);
    const known = builtin('code_assistant');
    expect(result.current.localizedName(known)).toBe('Code Assistant');
    expect(result.current.localizedStarterMessages(known)).toEqual(['Fix this bug']);
  });
});
