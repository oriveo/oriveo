package ai.oriveo.community.di

import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.security.SecureKeyStore
import ai.oriveo.community.feature.chat.attachments.AttachmentProcessor
import org.koin.android.ext.koin.androidContext
import org.koin.dsl.module

val securityModule = module {
    single { SecureKeyStore(androidContext()) }
    single { AttachmentStore(androidContext()) }
    single { AttachmentProcessor(attachmentStore = get()) }
}
