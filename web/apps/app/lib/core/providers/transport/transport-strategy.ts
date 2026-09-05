/**
 * Transport strategy lives in @oriveo/core so every host imports the same implementation.
 * This module re-exports it so local importers can keep using this path.
 */
export * from '@oriveo/core/providers/transport/transport-strategy';
