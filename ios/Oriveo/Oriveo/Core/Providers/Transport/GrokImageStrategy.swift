import Foundation

/// `transport=grok_image`:xAI Grok Imagine(grok-imagine-image / pro).
struct GrokImageStrategy: TransportStrategy {
    let kind: TransportKind = .grokImage

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        _ = raw; _ = ctx; _ = shape
        return []
    }
}
