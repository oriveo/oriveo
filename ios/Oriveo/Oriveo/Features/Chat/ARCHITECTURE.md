# Chat architecture (iOS)

High-level notes for the chat surface.

## Stack

- **SwiftUI shell** hosts a UIKit `UICollectionView` backed by ChatLayout SPM (`CollectionViewChatLayout`).
- **Cells** are primarily UIKit (self-sizing). Some lightweight chrome still uses SwiftUI via hosting where needed.
- **`ChatListViewController`** owns data-source updates, stick-to-bottom behavior, and settle after keyboard/inset changes.
- **`ChatStickToBottomController`** keeps the latest content pinned when the user is following the bottom; user scroll up disables follow until they return.

## Streaming / block render

- Streaming text is chunked into syntax-complete blocks where possible, then committed to the list.
- Table/code cards use dedicated UIKit renderers so partial Markdown does not thrash layout.
- Prefer block-level fade-in over re-rendering entire messages on every token.

## Stick-to-bottom / runway

- Bottom content inset (“runway”) absorbs growth while following the bottom so the viewport does not jump.
- Gesture and keyboard coordinators adjust the effective viewport; see unit tests under `OriveoTests/Features/Chat/`.

## Debugging scroll jumps

1. Confirm whether the user is in follow-bottom mode.
2. Check bottom inset / runway adjustments during streaming growth.
3. Check table/code card intrinsic size changes mid-stream.

## Related tests

- Row height parity / estimate tests
- Streaming block chunker and table rendering tests
- Scroll gesture + keyboard coordinator suites
- Recovery card layout collapse tests
