export async function loadAttachmentUtils(): Promise<typeof import('./attachment-utils')> {
  return import('./attachment-utils');
}
