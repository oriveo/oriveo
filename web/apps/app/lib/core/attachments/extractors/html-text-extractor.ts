/**
 * HTML/XHTML/SVG text extraction.
 *
 * Uses DOMParser in the browser; the SSR fallback strips tags with a regex.
 */

export async function extractHtmlText(file: File): Promise<string> {
  const html = await file.text();

  if (typeof DOMParser === 'undefined') {
    // SSR fallback: strip tags with a simple regex
    return html
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<noscript[\s\S]*?<\/noscript>/gi, '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
  }

  const parser = new DOMParser();
  const doc = parser.parseFromString(html, 'text/html');
  doc.querySelectorAll('script, style, noscript').forEach((el) => el.remove());
  const text = doc.body?.textContent ?? '';
  return text.replace(/\s+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
