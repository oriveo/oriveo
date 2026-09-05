export const CHANNELS = {
  chat: {
    start: 'chat:stream:start',
    cancel: 'chat:stream:cancel',
    closed: 'chat:stream:closed',
  },
  provider: {
    validate: 'provider:validate',
    models: 'provider:models',
    clearUnsupportedParamLearning: 'provider:clear-unsupported-param-learning',
  },
  relay: {
    start: 'relay:forward:start',
    cancel: 'relay:forward:cancel',
    testConnection: 'relay:test-connection',
  },
  images: {
    generate: 'images:generate',
  },
  skills: {
    knowledgeUpload: 'skills:knowledge:upload',
    knowledgeRetrieve: 'skills:knowledge:retrieve:start',
    knowledgeFileStatus: 'skills:knowledge:file-status',
    knowledgeFileDelete: 'skills:knowledge:file-delete',
    knowledgeEligibility: 'skills:knowledge:eligibility',
    knowledgeCleanupDraft: 'skills:knowledge:cleanup-draft',
    knowledgeReplace: 'skills:knowledge:replace',
    knowledgeRetry: 'skills:knowledge:retry',
    knowledgeCancel: 'skills:knowledge:cancel',
  },
  knowledge: {
    createVectorStore: 'knowledge:create-vector-store',
    uploadFile: 'knowledge:upload-file',
    fileStatus: 'knowledge:file-status',
    deleteFile: 'knowledge:delete-file',
    deleteVectorStore: 'knowledge:delete-vector-store',
    retrieve: 'knowledge:retrieve',
  },
  keys: {
    set: 'keys:set',
    has: 'keys:has',
    delete: 'keys:delete',
    preview: 'keys:preview',
  },
  fs: {
    pick: 'fs:pick',
    meta: 'fs:meta',
    readHandle: 'fs:read-handle',
    readHandleAbort: 'fs:read-handle:abort',
  },
  sync: {
    stateChanged: 'sync:state-changed',
    conflictDetected: 'sync:conflict-detected',
    networkHint: 'sync:network-hint',
  },
  shell: {
    openExternal: 'shell:open-external',
    getInitialTheme: 'shell:get-initial-theme',
    themeChanged: 'shell:theme-changed',
    persistWindowState: 'shell:persist-window-state',
    setMenuLabels: 'shell:set-menu-labels',
    menuCommand: 'shell:menu-command',
    openContextMenu: 'shell:open-context-menu',
    windowControl: 'shell:window-control',
    isMaximized: 'shell:is-maximized',
    maximizeChanged: 'shell:maximize-changed',
    getPlatform: 'shell:get-platform',
  },
  deeplink: {
    navigate: 'deeplink:navigate',
  },
  telemetry: {
    syncIdentity: 'telemetry:sync-identity',
    syncConsent: 'telemetry:sync-consent',
    syncSuperProps: 'telemetry:sync-super-props',
    seedAnonymousId: 'telemetry:seed-anonymous-id',
  },
  // Only the background checkForUpdatesAndNotify in auto-update.ts is wired up. The bidirectional
  // renderer/main UpdateService and its preload bridge are not, so the channel definitions below
  // are kept for that but appear in no allowlist, which means there are no dangling channels.
  updater: {
    check: 'updater:check',
    download: 'updater:download',
    install: 'updater:install',
    status: 'updater:status',
    cancel: 'updater:cancel',
  },
} as const;

type Leaf<T> = T extends string ? T : T extends object ? Leaf<T[keyof T]> : never;

export type ChannelName = Leaf<typeof CHANNELS>;

export function flattenChannels(value: unknown): ChannelName[] {
  if (typeof value === 'string') return [value as ChannelName];
  if (!value || typeof value !== 'object') return [];
  return Object.values(value).flatMap((child) => flattenChannels(child));
}

export const RENDERER_INVOKE_CHANNELS: ReadonlySet<ChannelName> = new Set([
  CHANNELS.chat.start,
  CHANNELS.provider.validate,
  CHANNELS.provider.models,
  CHANNELS.provider.clearUnsupportedParamLearning,
  CHANNELS.relay.start,
  CHANNELS.relay.testConnection,
  CHANNELS.images.generate,
  CHANNELS.skills.knowledgeUpload,
  CHANNELS.skills.knowledgeRetrieve,
  CHANNELS.skills.knowledgeFileStatus,
  CHANNELS.skills.knowledgeFileDelete,
  CHANNELS.skills.knowledgeEligibility,
  CHANNELS.skills.knowledgeCleanupDraft,
  CHANNELS.skills.knowledgeReplace,
  CHANNELS.skills.knowledgeRetry,
  CHANNELS.knowledge.createVectorStore,
  CHANNELS.knowledge.uploadFile,
  CHANNELS.knowledge.fileStatus,
  CHANNELS.knowledge.deleteFile,
  CHANNELS.knowledge.deleteVectorStore,
  CHANNELS.knowledge.retrieve,
  CHANNELS.keys.set,
  CHANNELS.keys.has,
  CHANNELS.keys.delete,
  CHANNELS.keys.preview,
  CHANNELS.fs.pick,
  CHANNELS.fs.meta,
  CHANNELS.fs.readHandle,
  CHANNELS.shell.openExternal,
  CHANNELS.shell.getInitialTheme,
  CHANNELS.shell.openContextMenu,
  CHANNELS.shell.isMaximized,
  CHANNELS.shell.getPlatform,
  // updater.check/download/install are not exposed: there is no main handler for them.
]);

export const RENDERER_SEND_CHANNELS: ReadonlySet<ChannelName> = new Set([
  CHANNELS.chat.cancel,
  CHANNELS.relay.cancel,
  CHANNELS.skills.knowledgeCancel,
  CHANNELS.fs.readHandleAbort,
  CHANNELS.shell.persistWindowState,
  CHANNELS.shell.setMenuLabels,
  CHANNELS.shell.windowControl,
  CHANNELS.telemetry.syncIdentity,
  CHANNELS.telemetry.syncConsent,
  CHANNELS.telemetry.syncSuperProps,
  // updater.cancel is not exposed.
]);

export const MAIN_EVENT_CHANNELS: ReadonlySet<ChannelName> = new Set([
  CHANNELS.chat.closed,
  CHANNELS.sync.stateChanged,
  CHANNELS.sync.conflictDetected,
  CHANNELS.sync.networkHint,
  CHANNELS.shell.themeChanged,
  CHANNELS.shell.menuCommand,
  CHANNELS.shell.maximizeChanged,
  CHANNELS.deeplink.navigate,
  // updater.status is not exposed: nothing in main pushes it.
]);

export const REGISTERED_CHANNELS: ReadonlySet<ChannelName> = new Set(flattenChannels(CHANNELS));

export const ALLOWED_CHANNELS = new Set([...RENDERER_INVOKE_CHANNELS, ...RENDERER_SEND_CHANNELS]);
