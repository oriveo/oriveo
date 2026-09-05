import { describe, expect, it } from 'vitest';
import { resolveDocumentTitle, type RouteTitleKey } from './document-title';

const labels: Record<RouteTitleKey, string> = {
  backup: 'Backup & Data',
  chat: 'Chat',
  folder: 'Folder',
  manualModel: 'Manual Model Entry',
  memory: 'Memory',
  providerList: 'Providers',
  providerSetup: 'Add Provider',
  relaySetup: 'Add Relay',
  settings: 'Settings',
  skills: 'Skills',
  skillEdit: 'Edit Skill',
  welcome: 'Welcome to Oriveo',
};

describe('resolveDocumentTitle', () => {
  it('maps representative static routes to localized page titles', () => {
    expect(resolveDocumentTitle('/providers', labels, 'Oriveo')).toBe('Providers | Oriveo');
    expect(resolveDocumentTitle('/settings/backup', labels, 'Oriveo')).toBe('Backup & Data | Oriveo');
    expect(resolveDocumentTitle('/skills', labels, 'Oriveo')).toBe('Skills | Oriveo');
  });

  it('maps representative dynamic routes to stable page titles', () => {
    expect(resolveDocumentTitle('/providers/openai', labels, 'Oriveo', { providerName: 'OpenAI' })).toBe('OpenAI | Oriveo');
    expect(resolveDocumentTitle('/providers/relay-1', labels, 'Oriveo', { providerName: 'Local Relay' })).toBe('Local Relay | Oriveo');
    expect(resolveDocumentTitle('/providers/openai/manual-model', labels, 'Oriveo')).toBe('Manual Model Entry | Oriveo');
    expect(resolveDocumentTitle('/chat/folder/folder-1', labels, 'Oriveo', { folderName: 'Work' })).toBe('Work | Oriveo');
  });

  it('keeps titles that already include the brand name from being double-suffixed', () => {
    expect(resolveDocumentTitle('/welcome', labels, 'Oriveo')).toBe('Welcome to Oriveo');
    expect(resolveDocumentTitle('/settings', labels, 'Oriveo')).toBe('Settings | Oriveo');
  });

  it('falls back to the chat title for conversation routes and the brand for unknown routes', () => {
    expect(resolveDocumentTitle('/chat/conversation-1', labels, 'Oriveo')).toBe('Chat | Oriveo');
    expect(resolveDocumentTitle('/somewhere-else', labels, 'Oriveo')).toBe('Oriveo');
  });
});
