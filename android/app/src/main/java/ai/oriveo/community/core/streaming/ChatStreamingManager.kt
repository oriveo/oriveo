package ai.oriveo.community.core.streaming

import ai.oriveo.community.core.data.repository.ChatRepository
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRequestOptions
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ReasoningMode
import ai.oriveo.community.core.model.SkillKnowledgeRetrievalContext
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext


class ChatStreamingManager(
    private val chatRepository: ChatRepository,
    
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private class StreamingSession(
        val conversationId: String,
        val outputs: ConversationStreamingOutputs,
        @Volatile var job: Job? = null,
        
        val startedAt: Long = System.currentTimeMillis(),
        
        @Volatile var userStopRequested: Boolean = false,
    ) {
        val text: MutableStateFlow<String> get() = outputs.streamingText
        val messageIdState: MutableStateFlow<String?> get() = outputs.streamingMessageId

        
        val reasoning: MutableStateFlow<String> get() = outputs.streamingReasoning

        
        val reasoningStartedAt: MutableStateFlow<Long?> get() = outputs.reasoningStartedAtMs
    }

    
    
    
    
    private val streamingExceptionHandler = CoroutineExceptionHandler { _, e ->
        android.util.Log.e("ChatStreamingManager", "streaming coroutine crashed: ${e.localizedMessage}", e)
    }
    private val scope = CoroutineScope(SupervisorJob() + dispatcher + streamingExceptionHandler)
    private val mutex = Mutex()

    
    
    private val sessions = ConcurrentHashMap<String, StreamingSession>()

    private val _streamingConversationIds = MutableStateFlow<Set<String>>(emptySet())

    
    val streamingConversationIds: StateFlow<Set<String>> = _streamingConversationIds.asStateFlow()

    private val _sessionsVersion = MutableStateFlow(0L)

    
    val sessionsVersion: StateFlow<Long> = _sessionsVersion.asStateFlow()

    
    val isAnyStreaming: Boolean get() = sessions.isNotEmpty()

    

    
    fun streamingText(conversationId: String): StateFlow<String> =
        sessions[conversationId]?.text?.asStateFlow() ?: EmptyTextFlow

    
    fun streamingMessageId(conversationId: String): StateFlow<String?> =
        sessions[conversationId]?.messageIdState?.asStateFlow() ?: EmptyMessageIdFlow

    
    fun streamingReasoning(conversationId: String): StateFlow<String> =
        sessions[conversationId]?.reasoning?.asStateFlow() ?: EmptyTextFlow

    
    fun streamingReasoningStartedAt(conversationId: String): StateFlow<Long?> =
        sessions[conversationId]?.reasoningStartedAt?.asStateFlow() ?: EmptyReasoningStartedAtFlow

    
    @OptIn(ExperimentalCoroutinesApi::class)
    fun reasoningActiveFlow(activeConversationId: StateFlow<String?>): Flow<Boolean> =
        combine(activeConversationId, sessionsVersion) { convId, _ -> convId }
            .flatMapLatest { convId ->
                if (convId == null) flowOf(null) else streamingReasoningStartedAt(convId)
            }
            .map { it != null }

    
    fun isBusyStreaming(conversationId: String): Boolean =
        sessions.containsKey(conversationId)

    
    fun streamStartedAt(conversationId: String): Long =
        sessions[conversationId]?.startedAt ?: 0L

    

    
    fun startStream(request: StreamRequest) {
        scope.launch {
            mutex.withLock {
                val convId = request.conversation.id

                
                sessions[convId]?.let { old ->
                    val oldJob = old.job
                    oldJob?.cancel()
                    oldJob?.join()
                }

                val outputs = ConversationStreamingOutputs(
                    streamingText = MutableStateFlow(""),
                    streamingMessageId = MutableStateFlow<String?>(null),
                    streamingReasoning = MutableStateFlow(""),
                )
                val session = StreamingSession(conversationId = convId, outputs = outputs)
                sessions[convId] = session
                _streamingConversationIds.value = sessions.keys.toSet()
                
                
                _sessionsVersion.value = _sessionsVersion.value + 1

                session.job = scope.launch {
                    try {
                        chatRepository.sendMessage(
                            conversation = request.conversation,
                            text = request.text,
                            provider = request.provider,
                            modelID = request.modelID,
                            existingMessages = request.existingMessages,
                            attachments = request.attachments,
                            quoteContext = request.quoteContext,
                            reasoningMode = request.reasoningMode,
                            webSearchEnabled = request.webSearchEnabled,
                            antiForgetText = request.antiForgetText,
                            requestOptions = request.requestOptions,
                            retrieval = request.retrieval,
                            outputs = outputs,
                            persistUserMessage = request.persistUserMessage,
                            userMessageAlreadyInHistory = request.userMessageAlreadyInHistory,
                            appendToAssistant = request.appendToAssistant,
                        )
                    } finally {
                        
                        
                        
                        if (sessions[convId] === session) {
                            sessions.remove(convId)
                            _streamingConversationIds.value = sessions.keys.toSet()
                            
                            _sessionsVersion.value = _sessionsVersion.value + 1
                        }
                    }
                }
            }
        }
    }

    
    fun stopStream(conversationId: String) {
        scope.launch {
            mutex.withLock {
                
                sessions[conversationId]?.let { session ->
                    session.userStopRequested = true
                    session.job?.cancel()
                }
                
            }
        }
    }

    
    suspend fun stopStreamAndJoin(conversationId: String) {
        mutex.withLock {
            val session = sessions[conversationId] ?: return
            session.userStopRequested = true
            val job = session.job ?: return
            job.cancel()
            job.join()
        }
    }

    /** Stops every stream without waiting for them to finish. */
    fun stopAllStreams() {
        scope.launch {
            mutex.withLock {
                sessions.values.forEach { it.job?.cancel() }
            }
        }
    }

    /**
     * Stops every stream and waits for each one to unwind, so the caller knows the partial text
     * has been persisted before it continues.
     */
    suspend fun stopAllStreamsAndJoin() {
        mutex.withLock {
            val jobs = sessions.values.mapNotNull { session ->
                session.userStopRequested = true
                session.job?.also { it.cancel() }
            }
            jobs.forEach { it.join() }
        }
    }

    
    suspend fun flushAllPartialsToMessage() {
        withContext(NonCancellable) {
            coroutineScope {
                for ((_, session) in sessions) {
                    val text = session.text.value
                    val reasoning = session.reasoning.value
                    val msgId = session.messageIdState.value ?: continue
                    if (text.isBlank() && reasoning.isBlank()) continue
                    launch {
                        chatRepository.flushPartialToMessage(
                            messageId = msgId,
                            text = text,
                            reasoningText = reasoning,
                        )
                    }
                }
            }
        }
    }

    private companion object {
        private val EmptyTextFlow: StateFlow<String> = MutableStateFlow("").asStateFlow()
        private val EmptyMessageIdFlow: StateFlow<String?> = MutableStateFlow<String?>(null).asStateFlow()
        private val EmptyReasoningStartedAtFlow: StateFlow<Long?> =
            MutableStateFlow<Long?>(null).asStateFlow()
    }
}


data class StreamRequest(
    val conversation: Conversation,
    val text: String,
    val provider: Provider,
    val modelID: String,
    val existingMessages: List<ChatMessage>,
    val attachments: List<Attachment>? = null,
    val quoteContext: ai.oriveo.community.core.model.QuoteContext? = null,
    val reasoningMode: ReasoningMode = ReasoningMode.Automatic,
    val webSearchEnabled: Boolean = false,
    val antiForgetText: String? = null,
    val requestOptions: ChatRequestOptions = ChatRequestOptions(),
    val retrieval: SkillKnowledgeRetrievalContext? = null,
    val persistUserMessage: Boolean = true,
    val userMessageAlreadyInHistory: Boolean = false,
    /** An existing assistant message to continue rather than starting a new one. */
    val appendToAssistant: ChatMessage? = null,
)
