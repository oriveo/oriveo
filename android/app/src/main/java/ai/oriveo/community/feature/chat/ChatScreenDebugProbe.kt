package ai.oriveo.community.feature.chat

import java.lang.ref.WeakReference

/**
 * Debug-only handle on the chat page's current [ChatViewModel] for instrumentation tests: the view model lives in
 * the navigation back stack, so a test has no other way to read the list the page renders. [ChatScreen] registers
 * it only in debug builds and clears it on dispose; release builds never register.
 */
object ChatScreenDebugProbe {
    @Volatile
    private var current: WeakReference<ChatViewModel>? = null

    /** The registered view model, or null when no chat page is composed (or it was collected). */
    val viewModel: ChatViewModel? get() = current?.get()

    internal fun register(viewModel: ChatViewModel) {
        current = WeakReference(viewModel)
    }

    internal fun unregister(viewModel: ChatViewModel) {
        if (current?.get() === viewModel) current = null
    }
}
