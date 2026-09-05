package ai.oriveo.community.core.error

import android.system.ErrnoException
import java.io.EOFException
import java.io.IOException
import java.io.InterruptedIOException
import java.net.ProtocolException
import java.net.SocketException
import java.net.UnknownHostException
import java.net.UnknownServiceException
import javax.net.ssl.SSLException

/**
 * Tells "the connection dropped" apart from "our code is wrong".
 *
 * Streaming a chat completion fails constantly for reasons nobody can fix: the phone walks out of
 * Wi-Fi range, Doze suspends the socket, the user taps stop. Those must reach the user as a plain
 * "check your connection" message, while a real defect must keep its original message so the stack
 * trace still means something.
 */

/** Cancellation counts as transient: the user stopping generation is not a failure. */
fun Throwable.isTransientNetworkOrCancellation(): Boolean {
    if (this is kotlinx.coroutines.CancellationException) return true
    if (isProgrammingError()) return false
    return causeChain().any {
        it is kotlinx.coroutines.CancellationException || it.isTransientNetworkNode()
    }
}

/**
 * Transport failures only, without cancellation.
 *
 * Callers that render a message need the distinction: "check your connection" is the right words
 * for a dropped socket and the wrong words for a user who just tapped stop.
 */
fun Throwable.isTransientNetworkFailure(): Boolean {
    if (isProgrammingError()) return false
    return causeChain().any { it.isTransientNetworkNode() }
}

/**
 * A programming error on the outside never gets the cause-chain exemption.
 *
 * Walking the cause chain has a built-in cost: a genuine local bug is waved through as soon as any
 * network exception hangs off it. But network failure is an expected operating condition that this
 * code is supposed to handle; the moment it surfaces as an NPE or an ISE, the handling itself is
 * broken, and that is exactly the case worth surfacing.
 *
 * Must run after the cancellation check: `java.util.concurrent.CancellationException` extends
 * `IllegalStateException`, so the reverse order turns "user stopped generation" back into a defect.
 */
private fun Throwable.isProgrammingError(): Boolean = when (this) {
    is NullPointerException,
    is IllegalStateException,
    is IllegalArgumentException,
    is ClassCastException,
    is IndexOutOfBoundsException,
    is ConcurrentModificationException,
    is UnsupportedOperationException,
    -> true
    else -> false
}

private const val MAX_CAUSE_CHAIN_DEPTH = 6

/**
 * The throwable plus its cause chain. `!==` stops self-references (`initCause(this)`, or an SDK
 * that reuses one instance); the depth cap stops longer cycles. Without both, the walk hangs.
 */
private fun Throwable.causeChain(): Sequence<Throwable> = sequence {
    var node: Throwable = this@causeChain
    var remainingDepth = MAX_CAUSE_CHAIN_DEPTH
    while (true) {
        yield(node)
        remainingDepth -= 1
        if (remainingDepth <= 0) break
        node = node.cause?.takeIf { it !== node } ?: break
    }
}

/**
 * Whether a single node in the chain is a transient transport failure.
 *
 * JDK and Android types are matched by inheritance so a whole family is covered at once. Matching
 * on class-name suffixes instead means every unlisted subclass silently reads as a local defect.
 *
 * [java.net.UnknownServiceException] is deliberately excluded. OkHttp raises it for "CLEARTEXT not
 * permitted", which is a configuration problem, not a flaky link: relay endpoints are forced to
 * HTTPS, so seeing it means something bypassed that policy and the caller should hear about it.
 */
private fun Throwable.isTransientNetworkNode(): Boolean {
    if (this is UnknownServiceException) return false
    val isTransientType = when (this) {
        is SocketException, // Connect / NoRouteToHost / PortUnreachable / Bind
        is SSLException, // Handshake / PeerUnverified / Protocol / Key
        is UnknownHostException,
        is InterruptedIOException, // includes SocketTimeoutException
        is EOFException,
        is ProtocolException,
        is ErrnoException,
        -> true
        else -> false
    }
    if (isTransientType) return true
    val className = this::class.qualifiedName.orEmpty()
    if (TRANSIENT_NETWORK_EXCEPTION_CLASSES.any { className.endsWith(it) }) return true
    if (this is IOException) {
        val message = this.message.orEmpty()
        if (TRANSIENT_NETWORK_MESSAGE_PATTERNS.any { message.contains(it, ignoreCase = true) }) return true
    }
    return false
}

/**
 * Only the two kinds inheritance cannot reach:
 *
 * 1. Types in `internal` packages. Importing them directly draws R8 warnings on some Kotlin
 *    versions and can throw `IllegalAccessError` at runtime; a suffix match avoids the
 *    compile-time dependency and survives the class moving to another package.
 * 2. Library types that extend `IOException` directly and share no network base class.
 */
private val TRANSIENT_NETWORK_EXCEPTION_CLASSES = setOf(
    // OkHttp HTTP/2 streaming
    "StreamResetException",
    "ConnectionShutdownException",
    "ClosedByteChannelException",
    // java.nio.channels.ClosedChannelException extends IOException directly
    "ClosedChannelException",
    // Ktor timeouts extend IOException directly and may carry a null cause, so walking the chain
    // does not necessarily reach a SocketTimeoutException
    "ConnectTimeoutException",
    "HttpRequestTimeoutException",
)

private val TRANSIENT_NETWORK_MESSAGE_PATTERNS = listOf(
    "stream was reset",
    "Software caused connection abort",
    "Connection reset",
    "Connection closed",
    "Connection refused",
    "exhausted all routes",
    "Required SETTINGS preface not received",
    "Canceled",
)
