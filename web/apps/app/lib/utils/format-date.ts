/**
 * Renders an ISO date string as a long date in the target locale.
 * Falls back to the default locale when the browser does not support the requested one, and returns the input unchanged when ISO parsing fails.
 */
export function formatLocaleDate(iso: string, locale: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  try {
    return d.toLocaleDateString(locale, { year: 'numeric', month: 'long', day: 'numeric' });
  } catch {
    return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
  }
}
