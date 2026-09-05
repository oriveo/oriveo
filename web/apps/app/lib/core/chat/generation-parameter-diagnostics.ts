const STORAGE_KEY = 'oriveo.generation-parameter-diagnostics.v1';
const MAX_ENTRIES = 50;

export type GenerationParameterDiagnostic = {
  id: string;
  createdAt: string;
  parameter: string;
  status: 'recovered' | 'retry_exhausted' | 'resolved';
  transport: string;
  errorClass: 'unsupported_parameter' | 'none';
  phase: 'before_first_token' | 'configuration';
  modelId?: string;
};

export function listGenerationParameterDiagnostics(): GenerationParameterDiagnostic[] {
  if (typeof window === 'undefined') return [];
  try {
    const parsed: unknown = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '[]');
    return Array.isArray(parsed) ? parsed.filter(isDiagnostic).slice(0, MAX_ENTRIES) : [];
  } catch {
    return [];
  }
}

export function recordGenerationParameterDiagnostic(
  value: Omit<GenerationParameterDiagnostic, 'id' | 'createdAt'>,
): void {
  if (typeof window === 'undefined' || !/^[A-Za-z0-9_.-]{1,80}$/.test(value.parameter)) return;
  const entry: GenerationParameterDiagnostic = {
    ...value,
    id: globalThis.crypto?.randomUUID?.() ?? `diagnostic_${Date.now()}`,
    createdAt: new Date().toISOString(),
  };
  localStorage.setItem(STORAGE_KEY, JSON.stringify([entry, ...listGenerationParameterDiagnostics()].slice(0, MAX_ENTRIES)));
}

export function clearGenerationParameterDiagnostics(): void {
  if (typeof window !== 'undefined') localStorage.removeItem(STORAGE_KEY);
}

/** Redacted export omits local model/connection identifiers and every parameter value. */
export function exportGenerationParameterDiagnosticsJSON(): string {
  return JSON.stringify(listGenerationParameterDiagnostics().map(({ modelId: _, ...entry }) => entry), null, 2);
}

function isDiagnostic(value: unknown): value is GenerationParameterDiagnostic {
  if (!value || typeof value !== 'object') return false;
  const entry = value as Partial<GenerationParameterDiagnostic>;
  return typeof entry.id === 'string' && typeof entry.createdAt === 'string'
    && typeof entry.parameter === 'string' && typeof entry.status === 'string'
    && typeof entry.transport === 'string' && typeof entry.errorClass === 'string';
}
