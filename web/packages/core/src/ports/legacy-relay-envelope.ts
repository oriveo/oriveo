/**
 * Legacy Relay runtime capability bits (transport-level image / nativeFile etc.). Only providers/relay-runtime-support.ts
 * may decode them; ports/index.ts references this only for the structure of RelayRuntimeConfig and no longer exports it. The dependency graph is
 * locked twice: by ports/index.test.ts and by the eslint ban on importing legacy-relay-envelope.
 */
export interface RelayTransportEnvelope {
  image: boolean;
  nativeFile: boolean;
  textFileInline: boolean;
  webSearch: boolean;
  imageGeneration: boolean;
  reasoning: boolean;
}
