package ai.oriveo.community.core.studio

import android.content.Context
import ai.oriveo.community.core.studio.StudioByokTasks.QueueEffect
import ai.oriveo.community.core.studio.StudioByokTasks.QueueEvent
import ai.oriveo.community.core.studio.StudioByokTasks.QueueState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * Per-device BYOK image round queue: FIFO, at most [StudioByokTasks.MAX_CONCURRENT_ROUNDS] rounds running.
 * State changes only through [StudioByokTasks.reduce]. Cancelling a running round completes its cancel signal and
 * frees the slot at once; a response that arrives after that is dropped without an event. While any round runs,
 * [foreground] holds the shortService with the summed image count of the running rounds; a refused start does not
 * block execution and the service time limit never cancels a round. Queued is emitted only for a round that has to
 * wait; a run that throws anything but cancellation ends as [Event.Failed] and frees its slot.
 */
class StudioByokQueue<R>(
    private val scope: CoroutineScope,
    private val run: suspend (id: String, cancel: CompletableDeferred<Unit>) -> R,
    private val onUpdate: (id: String, event: Event<R>) -> Unit,
    private val foreground: Foreground,
) {
    sealed interface Event<out R> {
        data object Queued : Event<Nothing>
        data object Started : Event<Nothing>
        data class Result<R>(val value: R) : Event<R>
        data class Cancelled(val mayBeBilled: Boolean) : Event<Nothing>

        /** run threw a non-cancellation error; the slot is already freed. */
        data class Failed(val error: Throwable) : Event<Nothing>
    }

    /** Foreground holder; count is the summed image count of the running rounds. */
    interface Foreground {
        fun start(count: Int): Boolean
        fun update(count: Int)
        fun stop()
    }

    /** Default [Foreground] backed by [StudioGenerationServiceController]. */
    class ServiceForeground(private val context: Context) : Foreground {
        override fun start(count: Int): Boolean = StudioGenerationServiceController.start(context, count)

        override fun update(count: Int) {
            StudioGenerationServiceController.update(count)
        }

        override fun stop() {
            StudioGenerationServiceController.stop()
        }
    }

    private val lock = Any()
    private var state = QueueState()
    private val imageCounts = HashMap<String, Int>()
    private val cancels = HashMap<String, CompletableDeferred<Unit>>()
    private var foregroundCount = 0

    fun submit(id: String, imageCount: Int): Unit = synchronized(lock) {
        if (id in state.running || id in state.queued) return
        imageCounts[id] = imageCount
        apply(QueueEvent.Submit(id), result = null)
        // A round that started at once already got Started from launch; only a round left waiting is Queued.
        if (id in state.queued) onUpdate(id, Event.Queued)
    }

    fun cancel(id: String): Unit = synchronized(lock) {
        apply(QueueEvent.Cancel(id), result = null)
    }

    fun snapshot(): QueueState = synchronized(lock) { state }

    private fun respond(id: String, cancel: CompletableDeferred<Unit>, result: R) = synchronized(lock) {
        // A cancelled-then-resubmitted id must not take the old attempt's response.
        if (cancels[id] !== cancel) return
        apply(QueueEvent.Response(id), result)
    }

    private fun abandon(id: String, cancel: CompletableDeferred<Unit>, failure: Throwable?) = synchronized(lock) {
        if (cancels[id] !== cancel) return
        if (failure != null) onUpdate(id, Event.Failed(failure))
        apply(QueueEvent.Finish(id), result = null)
    }

    private fun apply(event: QueueEvent, result: R?) {
        val (next, effects) = StudioByokTasks.reduce(state, event)
        state = next
        for (effect in effects) {
            when (effect) {
                is QueueEffect.Start -> launch(effect.id)
                is QueueEffect.Cancelled -> {
                    cancels.remove(effect.id)?.complete(Unit)
                    imageCounts.remove(effect.id)
                    onUpdate(effect.id, Event.Cancelled(effect.mayBeBilled))
                }
                is QueueEffect.Accept -> {
                    @Suppress("UNCHECKED_CAST")
                    onUpdate(effect.id, Event.Result(result as R))
                    apply(QueueEvent.Finish(effect.id), result = null)
                }
                is QueueEffect.Drop -> Unit
            }
        }
        if (event is QueueEvent.Finish) {
            cancels.remove(event.id)
            imageCounts.remove(event.id)
        }
        syncForeground()
    }

    private fun launch(id: String) {
        val cancel = CompletableDeferred<Unit>()
        cancels[id] = cancel
        onUpdate(id, Event.Started)
        scope.launch {
            val result = try {
                run(id, cancel)
            } catch (error: CancellationException) {
                // Scope cancelled: free the slot and let the cancellation propagate.
                abandon(id, cancel, failure = null)
                throw error
            } catch (error: Throwable) {
                // run failed: report a Failed terminal state, free the slot, and do not rethrow.
                abandon(id, cancel, failure = error)
                return@launch
            }
            respond(id, cancel, result)
        }
    }

    private fun syncForeground() {
        val count = state.running.sumOf { imageCounts[it] ?: 0 }
        val previous = foregroundCount
        if (count == previous) return
        foregroundCount = count
        when {
            previous == 0 -> foreground.start(count)
            count == 0 -> foreground.stop()
            else -> foreground.update(count)
        }
    }
}
