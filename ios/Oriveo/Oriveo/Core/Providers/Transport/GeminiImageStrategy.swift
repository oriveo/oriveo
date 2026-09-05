import Foundation

struct GeminiImageStrategy: TransportStrategy {
    let kind: TransportKind = .geminiImage

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        _ = raw; _ = ctx; _ = shape
        return []
    }
}
