import Foundation

struct OpenAIImagesStrategy: TransportStrategy {
    let kind: TransportKind = .openaiImages

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        _ = raw; _ = ctx; _ = shape
        return []
    }
}
