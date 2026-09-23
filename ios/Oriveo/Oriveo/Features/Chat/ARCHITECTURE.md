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

## Long text

- TextKit lays text out paragraph by paragraph, and one unbroken paragraph gets slower faster than linearly (Arabic
  especially). Overlong paragraphs are split in the display string with U+2029 (`SoftParagraphBreaks`); everything that
  leaves a view (bindings, drafts, copy, Save as Note, Ask) gets the source text back.
- A text view whose height grows with its content must not join Auto Layout directly: UIKit computes its baseline on
  every constraint pass by laying the whole text out. The user bubble hosts its `ChatPassiveTextView` in
  `UserBubbleTextHost` and sizes it from one cached measurement (`UserBubbleTextLayout`). Configure sets the text
  view's frame to the measured size **before** filling in the text: TextKit 1 lays the whole text out synchronously on
  both storage edits and container geometry changes, so the reverse order lays a fresh cell out once more at the stale
  width.
- The composer and the Home hero use `ComposerTextView`, not SwiftUI `TextField(axis: .vertical)`, which lays the whole
  text out again for every size proposal. Pastes go through the paste delegate; every other whole-block insertion is
  split at the `insertText` / `shouldChangeTextIn` entry points before it is written, so an overlong paragraph never
  reaches storage.

## Debugging scroll jumps

1. Confirm whether the user is in follow-bottom mode.
2. Check bottom inset / runway adjustments during streaming growth.
3. Check table/code card intrinsic size changes mid-stream.

## Related tests

- Row height parity / estimate tests
- Streaming block chunker and table rendering tests
- Scroll gesture + keyboard coordinator suites
- Recovery card layout collapse tests
- Long text: `ComposerTextViewTests`, `UserBubbleLongTextTests`
