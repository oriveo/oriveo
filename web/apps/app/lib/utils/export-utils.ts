import type { Conversation, ChatMessage } from '@oriveo/shared';
import { copyToClipboard } from './clipboard';

export function exportAsMarkdown(conversation: Conversation): string {
  const lines: string[] = [`# ${conversation.title || 'Untitled'}`, ''];

  if (conversation.updatedAt) {
    lines.push(`*${new Date(conversation.updatedAt).toLocaleString()}*`, '');
  }

  for (const msg of conversation.messages) {
    const role = msg.role === 'user' ? 'User' : 'Assistant';
    lines.push(`## ${role}`, '');
    lines.push(msg.text, '');

    if (msg.role === 'assistant' && msg.modelName) {
      lines.push(`*Model: ${msg.modelName}${msg.providerName ? ` (${msg.providerName})` : ''}*`, '');
    }
  }

  return lines.join('\n');
}

export function exportAsJSON(conversation: Conversation): string {
  const exportData = {
    id: conversation.id,
    title: conversation.title,
    createdAt: conversation.updatedAt,
    messages: conversation.messages.map((msg) => ({
      role: msg.role,
      text: msg.text,
      model: msg.modelName,
      provider: msg.providerName,
      timestamp: undefined,
    })),
  };
  return JSON.stringify(exportData, null, 2);
}

export function downloadAsFile(content: string, filename: string, mimeType: string) {
  const blob = new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

export function copyAllToClipboard(conversation: Conversation): Promise<boolean> {
  const lines: string[] = [];
  for (const msg of conversation.messages) {
    const role = msg.role === 'user' ? 'User' : 'Assistant';
    lines.push(`${role}:\n${msg.text}\n`);
  }
  return copyToClipboard(lines.join('\n'));
}

export function sanitizeFilename(name: string): string {
  return name.replace(/[/\\?%*:|"<>]/g, '-').slice(0, 100);
}
