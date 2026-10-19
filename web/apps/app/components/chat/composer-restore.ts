/**
 * After a cancel at the pre-send confirmation or a block by the pre-send check, the original input is put back only if the composer is still empty:
 * it is refilled only when both text and attachments are empty, so text typed or files added while waiting for the confirmation are not overwritten.
 */
export function composerAcceptsRestore(current: { text: string; attachments: readonly unknown[] }): boolean {
  return current.text.trim().length === 0 && current.attachments.length === 0;
}
