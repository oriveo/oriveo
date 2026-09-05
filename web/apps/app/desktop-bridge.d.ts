/**
 * window.oriveo, exposed by the desktop preload through contextBridge. It exists only in the
 * Electron runtime and is undefined on the web. The types come from @oriveo/ipc-contract, which
 * apps/app already depends on; the renderer checks window.oriveo?.chat to detect the desktop build.
 */
import type {
  OriveoChatBridge,
  OriveoKeysBridge,
  OriveoKnowledgeBridge,
  OriveoProviderBridge,
} from '@oriveo/ipc-contract';

declare global {
  interface Window {
    oriveo?: {
      keys: OriveoKeysBridge;
      provider: OriveoProviderBridge;
      chat: OriveoChatBridge;
      knowledge: OriveoKnowledgeBridge;
    };
  }
}

export {};
