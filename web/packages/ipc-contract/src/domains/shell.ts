export type ThemePreference = 'light' | 'dark' | 'system';
export type ThemeResolved = 'light' | 'dark';

export type ShellRightTab = 'notes' | 'history' | 'skills' | 'memory';

export interface WindowBounds {
  x?: number;
  y?: number;
  width: number;
  height: number;
}

export interface WindowState {
  bounds: WindowBounds;
  isMaximized: boolean;
  isFullScreen: boolean;
  leftSidebarWidth: number;
  rightAsideWidth: number;
  leftCollapsed: boolean;
  rightCollapsed: boolean;
  rightTab: ShellRightTab;
}

export type WindowStatePatch = Partial<
  Pick<
    WindowState,
    'leftSidebarWidth' | 'rightAsideWidth' | 'leftCollapsed' | 'rightCollapsed' | 'rightTab'
  >
>;

export type MainWindowStatePatch = Partial<Omit<WindowState, 'bounds'>> & {
  bounds?: Partial<WindowBounds>;
};

export interface ShellOpenExternalRequest {
  url: string;
  allowlist: 'legal' | 'support' | 'provider-console';
}

export interface ShellSetMenuLabelsRequest {
  labels: Record<string, string>;
  locale: string;
}

export type ShellMenuCommand =
  | { command: 'new-chat' }
  | { command: 'open-command-palette' }
  | { command: 'toggle-left-sidebar' }
  | { command: 'toggle-right-aside' }
  | { command: 'focus-composer' }
  | { command: 'find-in-conversation' }
  | { command: 'navigate'; to: 'dashboard' | 'chat' | 'providers' | 'skills' | 'notes' | 'settings' }
  | { command: 'open-settings' }
  | { command: 'open-backup' }
  | { command: 'prev-conversation' | 'next-conversation' }
  | { command: 'open-shortcuts-cheatsheet' }
  | {
      command:
        | 'reload'
        | 'toggle-fullscreen'
        | 'zoom-in'
        | 'zoom-out'
        | 'zoom-reset'
        | 'minimize'
        | 'close';
    };

export type ContextMenuRegion =
  | 'message'
  | 'selection'
  | 'conversation'
  | 'note-card'
  | 'provider-card'
  | 'skill-card'
  | 'generic';

export type ContextMenuItem =
  | { actionId: string; label: string; accelerator?: string; danger?: boolean }
  | { separator: true };

export interface ContextMenuRequest {
  region: ContextMenuRegion;
  items: ContextMenuItem[];
}

export type WindowControlAction = 'minimize' | 'maximize-toggle' | 'close';

export interface ShellPlatformInfo {
  platform: 'darwin' | 'win32' | 'linux';
  modifierLabel: {
    meta: string;
    alt: string;
    shift: string;
  };
}

/**
 * The narrow interface preload exposes to the renderer through contextBridge
 * (window.oriveoShell). Pure type contract shared by preload and renderer to prevent drift.
 */
export interface OriveoShellBridge {
  /** Returns the initial theme computed by main at startup, synchronously, so dataset.theme can be set before React mounts and avoid a white flash. */
  getInitialTheme(): ThemeResolved;
  /** Subscribes to system theme changes; returns the unsubscribe function. */
  onThemeChange(cb: (theme: ThemeResolved) => void): () => void;
  /** One-way report of window and split state, called by the renderer after debouncing. */
  persistWindowState(patch: WindowStatePatch): void;
  /** Subscribe to native menu and accelerator commands; returns an unsubscribe function. */
  onMenuCommand(cb: (cmd: ShellMenuCommand) => void): () => void;
  /** Request a native context menu and resolve with the chosen actionId, or null when cancelled. */
  openContextMenu(req: ContextMenuRequest): Promise<string | null>;
  /** Custom-drawn window controls (Windows and Linux). */
  windowControl(action: WindowControlAction): void;
  /** Whether the window is currently maximized. */
  isMaximized(): Promise<boolean>;
  /** Subscribes to maximize-state changes; returns the unsubscribe function. */
  onMaximizeChange(cb: (maximized: boolean) => void): () => void;
  /** Platform information: window control layout and shortcut modifier display. */
  getPlatform(): Promise<ShellPlatformInfo>;
  /** Controlled external link opening (https only, allowlisted by category). */
  openExternal(req: ShellOpenExternalRequest): Promise<void>;
}
