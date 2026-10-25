import Foundation

/// Upstream rejection signature table. Reads the in-app mirror
/// `Core/Capability/RejectionSignatures/rejection-signatures.v1.json`.
///
/// Only `byWireFamily` and `byProtocol` are used; `candidates` / `notFound` do not take part. Matching: the
/// status code is equal; when `errorCode` is present it must equal `error.type` or `error.code`;
/// `messagePattern` is a case-insensitive regex tested against `error.message`. The wire families carried by
/// the request are checked first in `byWireFamily`, then the protocol's `byProtocol`; within a group the file
/// order applies and the first match wins. Anything not in the table returns nil (the raw error is shown,
/// nothing is inferred).
nonisolated struct InputRejectionSignatures: @unchecked Sendable {
    struct Signature: @unchecked Sendable {
        let signatureId: String
        let httpStatus: Int
        let errorCode: String?
        let messagePattern: String
        let kind: String
        let capabilityKey: String?
        let parameter: String?
        fileprivate let regex: NSRegularExpression
    }

    static let resourceName = "rejection-signatures.v1"
    static let shared: InputRejectionSignatures = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = InputRejectionSignatures(data: data) else {
            return InputRejectionSignatures(byWireFamily: [:], byProtocol: [:])
        }
        return table
    }()

    let byWireFamily: [String: [Signature]]
    let byProtocol: [String: [Signature]]

    private init(byWireFamily: [String: [Signature]], byProtocol: [String: [Signature]]) {
        self.byWireFamily = byWireFamily
        self.byProtocol = byProtocol
    }

    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.byWireFamily = Self.parseGroups(root["byWireFamily"])
        self.byProtocol = Self.parseGroups(root["byProtocol"])
    }

    /// `wireFamilies` = the wire families the request actually carried (e.g. `openai_chat.image_url`), checked in the caller's order.
    func match(status: Int, body: Data, protocol wireProtocol: String, wireFamilies: [String] = []) -> Signature? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        let codes = Set([error["type"], error["code"]].compactMap { $0 as? String })
        let range = NSRange(message.startIndex..., in: message)
        let groups = wireFamilies.map { byWireFamily[$0] ?? [] } + [byProtocol[wireProtocol] ?? []]
        for signature in groups.joined() {
            guard signature.httpStatus == status else { continue }
            if let errorCode = signature.errorCode, !codes.contains(errorCode) { continue }
            if signature.regex.firstMatch(in: message, range: range) != nil { return signature }
        }
        return nil
    }

    func signatureId(status: Int, body: Data, protocol wireProtocol: String, wireFamilies: [String] = []) -> String? {
        match(status: status, body: body, protocol: wireProtocol, wireFamilies: wireFamilies)?.signatureId
    }

    private static func parseGroups(_ value: Any?) -> [String: [Signature]] {
        guard let groups = value as? [String: Any] else { return [:] }
        var result: [String: [Signature]] = [:]
        for (key, raw) in groups {
            guard let list = raw as? [[String: Any]] else { continue }
            result[key] = list.compactMap(parseSignature)
        }
        return result
    }

    private static func parseSignature(_ raw: [String: Any]) -> Signature? {
        guard let signatureId = raw["signatureId"] as? String,
              let httpStatus = raw["httpStatus"] as? Int,
              let pattern = raw["messagePattern"] as? String,
              let kind = raw["kind"] as? String,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        return Signature(
            signatureId: signatureId, httpStatus: httpStatus, errorCode: raw["errorCode"] as? String,
            messagePattern: pattern, kind: kind, capabilityKey: raw["capabilityKey"] as? String,
            parameter: raw["parameter"] as? String, regex: regex
        )
    }
}
