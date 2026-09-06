package ai.oriveo.community.ui.component.markdown

import android.content.ClipboardManager
import android.content.Context
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.TextToolbar
import androidx.compose.ui.platform.TextToolbarStatus
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.R

internal class NoteSelectionTextToolbar(
    private val view: View,
    addToNoteLabel: String,
    askLabel: String?,
    replaceCurrentNoteLabel: String?,
    private val onSaveSelection: (String) -> Unit,
    private val onAskSelection: ((String) -> Unit)? = null,
    private val onReplaceSelection: ((String) -> Unit)? = null,
    private val onVisibilityChange: (Boolean) -> Unit = {},
) : TextToolbar {

    private var actionMode: ActionMode? = null
    private var statusField: TextToolbarStatus = TextToolbarStatus.Hidden
    private val callback = NoteSelectionActionModeCallback(
        addToNoteLabel = addToNoteLabel,
        askLabel = askLabel,
        replaceCurrentNoteLabel = replaceCurrentNoteLabel,
        onAddToNote = ::addSelectionToNote,
        onAsk = ::askSelection,
        onReplaceCurrentNote = ::replaceCurrentNote,
        onActionModeDestroy = { destroyed ->

            if (destroyed === actionMode) {
                actionMode = null
                statusField = TextToolbarStatus.Hidden
                onVisibilityChange(false)
            }
        },
    )

    override val status: TextToolbarStatus
        get() = statusField

    override fun showMenu(
        rect: Rect,
        onCopyRequested: (() -> Unit)?,
        onPasteRequested: (() -> Unit)?,
        onCutRequested: (() -> Unit)?,
        onSelectAllRequested: (() -> Unit)?,
    ) {
        onVisibilityChange(true)
        callback.update(
            rect = rect,
            onCopyRequested = onCopyRequested,
            onPasteRequested = onPasteRequested,
            onCutRequested = onCutRequested,
            onSelectAllRequested = onSelectAllRequested,
        )
        statusField = TextToolbarStatus.Shown
        val mode = actionMode
        if (mode == null) {
            actionMode = view.startActionMode(callback, ActionMode.TYPE_FLOATING)
        } else {

            mode.invalidateContentRect()
            mode.invalidate()
        }
    }

    override fun hide() {
        statusField = TextToolbarStatus.Hidden
        onVisibilityChange(false)
        actionMode?.finish()
        actionMode = null
    }

    private fun addSelectionToNote() {
        captureSelection(onSaveSelection)
    }

    private fun askSelection() {
        val ask = onAskSelection ?: return
        captureSelection(ask)
    }

    private fun replaceCurrentNote() {
        val replace = onReplaceSelection ?: return
        captureSelection(replace)
    }

    private fun captureSelection(action: (String) -> Unit) {
        callback.onCopyRequested?.invoke()

        val selected = readPrimaryClipText()?.trim()
        if (!selected.isNullOrBlank()) {
            action(selected)
        }
    }

    private fun readPrimaryClipText(): String? {
        val clipboard = view.context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return null
        val clip = clipboard.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        val item = clip.getItemAt(0) ?: return null

        item.text?.let { return it.toString() }
        return item.coerceToText(view.context)?.toString()
    }
}

private class NoteSelectionActionModeCallback(
    private val addToNoteLabel: String,
    private val askLabel: String?,
    private val replaceCurrentNoteLabel: String?,
    private val onAddToNote: () -> Unit,
    private val onAsk: () -> Unit,
    private val onReplaceCurrentNote: () -> Unit,
    private val onActionModeDestroy: (ActionMode) -> Unit,
) : ActionMode.Callback2() {

    private var rect: Rect = Rect.Zero
    var onCopyRequested: (() -> Unit)? = null
        private set
    private var onPasteRequested: (() -> Unit)? = null
    private var onCutRequested: (() -> Unit)? = null
    private var onSelectAllRequested: (() -> Unit)? = null

    fun update(
        rect: Rect,
        onCopyRequested: (() -> Unit)?,
        onPasteRequested: (() -> Unit)?,
        onCutRequested: (() -> Unit)?,
        onSelectAllRequested: (() -> Unit)?,
    ) {
        this.rect = rect
        this.onCopyRequested = onCopyRequested
        this.onPasteRequested = onPasteRequested
        this.onCutRequested = onCutRequested
        this.onSelectAllRequested = onSelectAllRequested
    }

    override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
        if (askLabel != null) {
            menu.add(GROUP_ADD_TO_NOTE, ID_ASK, ORDER_ASK, askLabel)
                .setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS or MenuItem.SHOW_AS_ACTION_WITH_TEXT)
        }

        menu.add(GROUP_ADD_TO_NOTE, ID_ADD_TO_NOTE, ORDER_ADD_TO_NOTE, addToNoteLabel)
            .setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS or MenuItem.SHOW_AS_ACTION_WITH_TEXT)
        if (replaceCurrentNoteLabel != null) {
            menu.add(GROUP_ADD_TO_NOTE, ID_REPLACE_CURRENT_NOTE, ORDER_REPLACE_CURRENT_NOTE, replaceCurrentNoteLabel)
                .setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS or MenuItem.SHOW_AS_ACTION_WITH_TEXT)
        }
        addStandardItems(menu)
        return true
    }

    override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean {

        menu.removeGroup(GROUP_STANDARD)
        addStandardItems(menu)
        return true
    }

    private fun addStandardItems(menu: Menu) {

        if (onCopyRequested != null) {
            menu.add(GROUP_STANDARD, ID_COPY, ORDER_COPY, android.R.string.copy)
                .setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS or MenuItem.SHOW_AS_ACTION_WITH_TEXT)
        }
        if (onPasteRequested != null) {
            menu.add(GROUP_STANDARD, ID_PASTE, ORDER_PASTE, android.R.string.paste)
                .setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS or MenuItem.SHOW_AS_ACTION_WITH_TEXT)
        }
        if (onCutRequested != null) {
            menu.add(GROUP_STANDARD, ID_CUT, ORDER_CUT, android.R.string.cut)
                .setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS or MenuItem.SHOW_AS_ACTION_WITH_TEXT)
        }
        if (onSelectAllRequested != null) {
            menu.add(GROUP_STANDARD, ID_SELECT_ALL, ORDER_SELECT_ALL, android.R.string.selectAll)
                .setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS or MenuItem.SHOW_AS_ACTION_WITH_TEXT)
        }
    }

    override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
        when (item.itemId) {
            ID_ASK -> onAsk()
            ID_ADD_TO_NOTE -> onAddToNote()
            ID_REPLACE_CURRENT_NOTE -> onReplaceCurrentNote()
            ID_COPY -> onCopyRequested?.invoke()
            ID_PASTE -> onPasteRequested?.invoke()
            ID_CUT -> onCutRequested?.invoke()

            ID_SELECT_ALL -> {
                onSelectAllRequested?.invoke()
                return true
            }
            else -> return false
        }
        mode.finish()
        return true
    }

    override fun onDestroyActionMode(mode: ActionMode) {
        onActionModeDestroy(mode)
    }

    override fun onGetContentRect(mode: ActionMode, view: View, outRect: android.graphics.Rect) {
        outRect.set(
            rect.left.toInt(),
            rect.top.toInt(),
            rect.right.toInt(),
            rect.bottom.toInt(),
        )
    }

    private companion object {
        const val GROUP_ADD_TO_NOTE = 0
        const val GROUP_STANDARD = 1

        const val ID_ADD_TO_NOTE = 0
        const val ID_ASK = 6
        const val ID_REPLACE_CURRENT_NOTE = 1
        const val ID_COPY = 2
        const val ID_PASTE = 3
        const val ID_CUT = 4
        const val ID_SELECT_ALL = 5

        const val ORDER_ASK = 0
        const val ORDER_ADD_TO_NOTE = 1
        const val ORDER_REPLACE_CURRENT_NOTE = 2
        const val ORDER_COPY = 3
        const val ORDER_PASTE = 4
        const val ORDER_CUT = 5
        const val ORDER_SELECT_ALL = 6
    }
}

@Composable
internal fun rememberNoteSelectionTextToolbar(
    onSaveSelection: (String) -> Unit,
    onAskSelection: ((String) -> Unit)? = null,
    onReplaceSelection: ((String) -> Unit)? = null,
    onVisibilityChange: (Boolean) -> Unit = {},
): TextToolbar {
    val view = LocalView.current
    val addLabel = stringResource(R.string.notes_chat_save_as_note)
    val askLabel = if (onAskSelection != null) stringResource(R.string.chat_selection_ask) else null
    val replaceLabel = if (onReplaceSelection != null) {
        stringResource(R.string.notes_chat_replace_current_note)
    } else {
        null
    }
    val latestOnSave = rememberUpdatedState(onSaveSelection)
    val latestOnAsk = rememberUpdatedState(onAskSelection)
    val latestOnReplace = rememberUpdatedState(onReplaceSelection)
    val latestOnVisibilityChange = rememberUpdatedState(onVisibilityChange)
    return remember(view, addLabel, askLabel, replaceLabel) {
        NoteSelectionTextToolbar(
            view = view,
            addToNoteLabel = addLabel,
            askLabel = askLabel,
            replaceCurrentNoteLabel = replaceLabel,
            onSaveSelection = { latestOnSave.value(it) },
            onAskSelection = { latestOnAsk.value?.invoke(it) },
            onReplaceSelection = { latestOnReplace.value?.invoke(it) },
            onVisibilityChange = { latestOnVisibilityChange.value(it) },
        )
    }
}
