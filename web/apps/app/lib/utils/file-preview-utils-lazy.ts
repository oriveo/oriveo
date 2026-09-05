export async function loadFilePreviewUtils(): Promise<typeof import('./file-preview-utils')> {
  return import('./file-preview-utils');
}
