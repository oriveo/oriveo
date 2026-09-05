export async function loadChatOperations(): Promise<typeof import('./operations')> {
  return import('./operations');
}
