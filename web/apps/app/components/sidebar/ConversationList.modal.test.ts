import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

function readConversationListSource(): string {
  return readFileSync(join(process.cwd(), 'components/sidebar/ConversationList.tsx'), 'utf8');
}

describe('ConversationList batch delete confirmation', () => {
  it('delegates batch-delete confirmation to the shared ConfirmDialog', () => {
    const source = readConversationListSource();
    // Bulk delete confirmation uses the shared <ConfirmDialog> (built on the @oriveo/ui Dialog:
    // centred in the viewport, does not cover the sidebar, portalled, with a focus trap), whose
    // behaviour is covered by ConfirmDialog.test. This test only guards that ConversationList
    // really goes through ConfirmDialog and has not fallen back to a hand-rolled inline portal modal.
    expect(source).toContain('ConfirmDialog');
    expect(source).toContain('showBatchConfirm');
    expect(source).not.toContain('createPortal');
  });
});
