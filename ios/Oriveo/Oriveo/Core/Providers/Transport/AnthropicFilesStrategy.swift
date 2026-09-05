import Foundation

struct AnthropicFilesStrategy: TransportStrategy {
    let kind: TransportKind = .anthropicFiles

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        _ = raw; _ = ctx; _ = shape
        return []
    }
}
