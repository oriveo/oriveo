import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

// The generation parameter panel exports redacted diagnostics, but the button borrowed the backup page's "Export"
// (pages.backup.export), the same name as the button in the same panel that really exports a backup. All three apps
// now say "Export diagnostics".

type Messages = {
  common?: Record<string, unknown>;
  pages?: { backup?: Record<string, unknown> };
};

function loadLocales(): Array<{ locale: string; messages: Messages }> {
  const messagesDir = join(process.cwd(), 'messages');
  return readdirSync(messagesDir)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((fileName) => ({
      locale: fileName.replace(/\.json$/, ''),
      messages: JSON.parse(readFileSync(join(messagesDir, fileName), 'utf8')) as Messages,
    }));
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

describe('generation diagnostics export label', () => {
  it('exists in every locale, is translated, and differs from the backup export label', () => {
    const locales = loadLocales();
    expect(locales).toHaveLength(16);
    const english = text(locales.find((entry) => entry.locale === 'en')?.messages.common?.generationDiagnosticsExport);
    expect(english).toBe('Export diagnostics');

    const problems = locales.flatMap(({ locale, messages }) => {
      const label = text(messages.common?.generationDiagnosticsExport);
      const issues: string[] = [];
      if (!label) issues.push(`${locale}: missing common.generationDiagnosticsExport`);
      if (locale !== 'en' && label === english) issues.push(`${locale}: still English`);
      if (label && label === text(messages.pages?.backup?.export)) issues.push(`${locale}: same as backup export`);
      return issues;
    });
    expect(problems).toEqual([]);
  });

  it('is what the diagnostics export button shows', () => {
    const source = readFileSync(join(process.cwd(), 'components/generation/GenerationParameterPanel.tsx'), 'utf8');
    const start = source.indexOf('exportGenerationParameterDiagnosticsJSON()');
    expect(start).toBeGreaterThan(0);
    const buttonEnd = source.indexOf('</button>', start);
    const button = source.slice(start, buttonEnd);
    expect(button).toContain("tc('generationDiagnosticsExport')");
    expect(button).not.toContain("backupT('export')");
  });
});
