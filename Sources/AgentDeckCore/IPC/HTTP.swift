import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
}

public enum HTTPParse: Equatable {
    case needMore, expectContinue, complete(HTTPRequest, consumed: Int), error(status: Int)
}

/// Stateless and pure. `.expectContinue` is returned on every call until the body completes; sending `100 Continue` once is the server's job.
public enum HTTPParser {
    private static let terminator = Data("\r\n\r\n".utf8)

    public static func parse(_ buffer: Data, maxHeader: Int = 16_384, maxBody: Int = 8_388_608) -> HTTPParse {
        let buf = Data(buffer)   // re-base: slices keep non-zero indices
        guard let r = buf.range(of: terminator) else { return buf.count > maxHeader ? .error(status: 431) : .needMore }
        let h = r.lowerBound
        if h + 4 > maxHeader { return .error(status: 431) }
        guard let head = String(data: buf[0..<h], encoding: .utf8) else { return .error(status: 400) }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[2].hasPrefix("HTTP/1.") else { return .error(status: 400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .error(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let method = String(parts[0])
        var length = 0
        if let cl = headers["content-length"] {
            guard !cl.isEmpty, cl.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(cl) else { return .error(status: 400) }
            length = n
        } else if method == "POST" || headers["transfer-encoding"] != nil {
            return .error(status: 411)
        }
        if length > maxBody { return .error(status: 413) }
        let bodyStart = h + 4
        if buf.count - bodyStart < length {
            return headers["expect"]?.lowercased() == "100-continue" ? .expectContinue : .needMore
        }
        let req = HTTPRequest(method: method, path: String(parts[1]), headers: headers, body: Data(buf[bodyStart..<(bodyStart + length)]))
        return .complete(req, consumed: bodyStart + length)
    }
}
