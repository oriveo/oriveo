// The telemetry vocabulary shared by every client, so an event means the same thing wherever it
// is recorded. Nothing here is sent anywhere unless a telemetry client is configured.

export type TelemetryPlatform = 'web-app' | 'ios' | 'android';

export type TelemetryPropertyValue =
  | string
  | number
  | boolean
  | null
  | undefined
  | readonly string[]
  | readonly number[];

export type TelemetryProperties = Record<string, TelemetryPropertyValue>;

export type TelemetryEventName =
  // Lifecycle
  | 'app_opened'
  | 'onboarding_step_viewed'
  | 'onboarding_completed'
  | 'bootstrap_timed_out'
  // Provider setup
  | 'provider_setup_started'
  | 'provider_added'
  | 'provider_key_validated'
  | 'provider_removed'
  | 'provider_setup_abandoned'
  // Chat
  | 'chat_started'
  | 'chat_message_sent'
  | 'chat_message_completed'
  | 'chat_message_failed'
  | 'chat_message_stopped'
  | 'message_regenerated'
  | 'model_switched'
  | 'model_picker_opened'
  | 'web_search_used'
  | 'reasoning_mode_changed'
  | 'library_research_route'
  | 'attachment_added'
  | 'selection_ask_attached'
  | 'selection_ask_removed'
  | 'selection_ask_sent'
  | 'image_generated'
  // Provider protocol health: a parameter the model rejected, or a shape this build cannot read.
  | 'self_heal_param_dropped'
  | 'metadata_base_url_rejected'
  | 'unknown_transport_kind'
  | 'tool_call_unhandled'
  | 'tool_call_capability_mismatch'
  // Local content
  | 'skill_used'
  | 'skill_created'
  | 'skill_forked'
  | 'memory_edited'
  | 'folder_created'
  | 'conversation_deleted'
  | 'backup_exported'
  | 'backup_imported'
  | 'settings_changed'
  // Attachment text extraction
  | 'file_extraction_started'
  | 'file_extraction_completed'
  | 'file_extraction_failed';

export const TELEMETRY_EVENTS: readonly TelemetryEventName[] = [
  'app_opened',
  'onboarding_step_viewed',
  'onboarding_completed',
  'bootstrap_timed_out',
  'provider_setup_started',
  'provider_added',
  'provider_key_validated',
  'provider_removed',
  'provider_setup_abandoned',
  'chat_started',
  'chat_message_sent',
  'chat_message_completed',
  'chat_message_failed',
  'chat_message_stopped',
  'message_regenerated',
  'model_switched',
  'model_picker_opened',
  'web_search_used',
  'reasoning_mode_changed',
  'library_research_route',
  'attachment_added',
  'selection_ask_attached',
  'selection_ask_removed',
  'selection_ask_sent',
  'image_generated',
  'self_heal_param_dropped',
  'metadata_base_url_rejected',
  'unknown_transport_kind',
  'tool_call_unhandled',
  'tool_call_capability_mismatch',
  'skill_used',
  'skill_created',
  'skill_forked',
  'memory_edited',
  'folder_created',
  'conversation_deleted',
  'backup_exported',
  'backup_imported',
  'settings_changed',
  'file_extraction_started',
  'file_extraction_completed',
  'file_extraction_failed',
] as const;

// Property names that must never reach a telemetry sink, whichever client is recording. A
// conversation is the user's, and a key is a credential; neither belongs in an analytics payload.
export const TELEMETRY_PII_BLACKLIST: readonly string[] = [
  'apiKey',
  'api_key',
  'apikey',
  'authorization',
  'bearer',
  'password',
  'token',
  'message_content',
  'messageContent',
  'content',
  'prompt',
  'completion',
] as const;
