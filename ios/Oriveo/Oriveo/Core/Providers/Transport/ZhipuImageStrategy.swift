import Foundation

struct ZhipuImageStrategy: TransportStrategy {
    let kind: TransportKind = .zhipuImage

    func parseStreamLine(
        _ raw: String,
        ctx: inout StreamContext,
        shape: MetadataClient.StreamShape?
    ) -> [StreamEvent] {
        _ = raw; _ = ctx; _ = shape
        return []
    }
}
