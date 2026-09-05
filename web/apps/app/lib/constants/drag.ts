// Private MIME type for dragging conversations in the sidebar. Using a custom type rather than
// 'text/plain' means folder drop zones only accept in-app conversation drags, so text or files
// dragged in from outside are never mistaken for a conversation ID.
export const CONVERSATION_DRAG_MIME = 'application/x-oriveo-conversation';
