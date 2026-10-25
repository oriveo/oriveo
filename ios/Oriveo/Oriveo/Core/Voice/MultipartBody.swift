import Foundation

/// multipart/form-data request body; parts are encoded one by one in order.
nonisolated struct MultipartBody: Sendable, Hashable {

    nonisolated enum Part: Sendable, Hashable {
        case field(name: String, value: String)
        case file(name: String, fileName: String, contentType: String, data: Data)

        var name: String {
            switch self {
            case .field(let name, _): return name
            case .file(let name, _, _, _): return name
            }
        }
    }

    let boundary: String
    var parts: [Part]

    init(boundary: String = "Boundary-\(UUID().uuidString)", parts: [Part]) {
        self.boundary = boundary
        self.parts = parts
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Per part: --boundary, headers, blank line, content, CRLF; finally --boundary--.
    func encoded() -> Data {
        let lineBreak = "\r\n"
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\(lineBreak)".utf8))
            switch part {
            case .field(let name, let value):
                body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\(lineBreak)\(lineBreak)".utf8))
                body.append(Data(value.utf8))
            case .file(let name, let fileName, let contentType, let data):
                body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\(lineBreak)".utf8))
                body.append(Data("Content-Type: \(contentType)\(lineBreak)\(lineBreak)".utf8))
                body.append(data)
            }
            body.append(Data(lineBreak.utf8))
        }
        body.append(Data("--\(boundary)--\(lineBreak)".utf8))
        return body
    }
}
