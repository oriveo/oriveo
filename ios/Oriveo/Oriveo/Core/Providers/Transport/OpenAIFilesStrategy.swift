import Foundation

struct OpenAIFilesStrategy: TransportStrategy {
    let kind: TransportKind = .openaiFiles

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        _ = raw; _ = ctx; _ = shape
        return []
    }
}
