import Foundation

struct QwenImageStrategy: TransportStrategy {
    let kind: TransportKind = .qwenImage

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        _ = raw; _ = ctx; _ = shape
        return []
    }
}
