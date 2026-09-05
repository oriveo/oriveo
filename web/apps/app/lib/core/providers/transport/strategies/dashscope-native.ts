/**
 * Re-export shim. The implementation is a pure protocol core in @oriveo/core so every
 * consumer shares one copy; this keeps the existing import paths here working.
 */
export * from '@oriveo/core/providers/transport/strategies/dashscope-native';
