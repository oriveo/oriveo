import { showToast } from '../../components/Toast';

export interface CopyOptions {
  /** Toast shown after a successful copy, already translated by the caller. Omit it for no toast, for example when the button state gives the feedback. */
  successToast?: string;
  /** Toast shown after a failed copy, already translated by the caller. Omit it for no toast. */
  failureToast?: string;
}

/**
 * Unified clipboard copy: prefer navigator.clipboard.writeText and fall back to
 * execCommand('copy') when it is unavailable.
 *
 * - HTTPS / localhost secure contexts use the modern async Clipboard API
 * - HTTP, older browsers, or a denied permission fall back to a hidden textarea plus
 *   document.execCommand('copy')
 * - i18n is injected by the caller, so this utility layer does not depend on next-intl
 *
 * @returns whether the copy succeeded
 */
export async function copyToClipboard(text: string, options: CopyOptions = {}): Promise<boolean> {
  const ok = await writeToClipboard(text);
  if (ok) {
    if (options.successToast) showToast(options.successToast);
  } else if (options.failureToast) {
    showToast(options.failureToast);
  }
  return ok;
}

async function writeToClipboard(text: string): Promise<boolean> {
  // SSR or any environment without a DOM.
  if (typeof navigator === 'undefined' || typeof document === 'undefined') {
    return false;
  }

  // Modern async Clipboard API, which needs a secure context.
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // Secure context unavailable or permission denied: fall back to execCommand.
  }

  // Fallback for older browsers and non-secure contexts.
  try {
    const textarea = document.createElement('textarea');
    textarea.value = text;
    textarea.setAttribute('readonly', '');
    textarea.style.position = 'fixed';
    textarea.style.left = '-9999px';
    textarea.style.top = '0';
    document.body.appendChild(textarea);
    textarea.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(textarea);
    return ok;
  } catch {
    return false;
  }
}
