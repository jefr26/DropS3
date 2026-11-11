import Foundation
import CryptoKit

struct S3Error: LocalizedError {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? {
        message.isEmpty ? "S3 \(status) \(code)" : "S3 \(status) \(code): \(message)"
    }
}

struct S3Object: Sendable { let size: Int64; let etag: String }
struct S3Listing: Sendable { var keys: [String] = []; var prefixes: [String] = []; var nextToken: String? }

/// Minimal S3 client (SigV4, path-style addressing) — works with Garage, MinIO and AWS.
struct S3Client: Sendable {
    let scheme: String
    let host: String
    let port: Int?
    let region: String
    let bucket: String
    let accessKey: String
    let secretKey: String

    static let emptyHash = sha256Hex(Data())

    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 12 * 3600
        cfg.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: cfg)
    }()

    init?(_ destination: S3Destination, secret: String) {
        let d = destination.sanitized
        guard let url = URL(string: d.endpoint),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !d.bucket.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        let defaultPort = scheme == "https" ? 443 : 80
        self.port = url.port == defaultPort ? nil : url.port
        self.region = d.region.isEmpty ? "us-east-1" : d.region
        self.bucket = d.bucket
        self.accessKey = d.accessKey
        self.secretKey = secret.removingWhitespace
    }

    // MARK: Operations

    func checkBucket() async throws {
        _ = try await list(prefix: "", delimiter: "/", maxKeys: 1)
    }

    func list(prefix: String, delimiter: String? = nil, token: String? = nil, maxKeys: Int = 1000) async throws -> S3Listing {
        var q = ["list-type": "2", "prefix": prefix, "max-keys": String(maxKeys)]
        if let delimiter { q["delimiter"] = delimiter }
        if let token { q["continuation-token"] = token }
        let (data, _) = try await send(makeRequest("GET", query: q))
        let xml = XMLCollector.parse(data)
        var out = S3Listing()
        for (path, value) in xml {
            if path.hasSuffix("Contents/Key") { out.keys.append(value) }
            else if path.hasSuffix("CommonPrefixes/Prefix") { out.prefixes.append(value) }
            else if path.hasSuffix("NextContinuationToken"), !value.isEmpty { out.nextToken = value }
        }
        return out
    }

    func head(_ key: String) async throws -> S3Object {
        let (_, resp) = try await send(makeRequest("HEAD", key: key))
        let size = Int64(resp.value(forHTTPHeaderField: "Content-Length") ?? "") ?? -1
        return S3Object(size: size, etag: Self.etag(resp))
    }

    @discardableResult
    func putFile(_ key: String, file: URL, sha256: String) async throws -> String {
        let req = makeRequest("PUT", key: key, payloadHash: sha256)
        let (_, resp) = try await send(req, file: file)
        return Self.etag(resp)
    }

    @discardableResult
    func putData(_ key: String, data: Data, contentType: String? = nil) async throws -> String {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        let req = makeRequest("PUT", key: key, headers: headers, payloadHash: Self.sha256Hex(data))
        let (_, resp) = try await send(req, body: data)
        return Self.etag(resp)
    }

    /// Downloads an object to a temporary file the caller owns (and must remove).
    func download(_ key: String) async throws -> URL {
        let (tmp, resp) = try await Self.session.download(for: makeRequest("GET", key: key))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? Data(contentsOf: tmp)) ?? Data()
            try? FileManager.default.removeItem(at: tmp)
            throw Self.parseError(body, status: status)
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("drops3-\(UUID().uuidString).download")
        try FileManager.default.moveItem(at: tmp, to: kept)
        return kept
    }

    func delete(_ key: String) async throws {
        _ = try await send(makeRequest("DELETE", key: key))
    }

    func createMultipart(_ key: String) async throws -> String {
        let (data, _) = try await send(makeRequest("POST", key: key, query: ["uploads": ""]))
        guard let id = XMLCollector.parse(data).first(where: { $0.path.hasSuffix("UploadId") })?.value, !id.isEmpty else {
            throw S3Error(status: 200, code: "InvalidResponse", message: t("Sin UploadId", "Missing UploadId"))
        }
        return id
    }

    func uploadPart(_ key: String, uploadId: String, number: Int, data: Data) async throws -> String {
        let req = makeRequest("PUT", key: key, query: ["partNumber": String(number), "uploadId": uploadId],
                              payloadHash: Self.sha256Hex(data))
        let (_, resp) = try await send(req, body: data)
        return Self.etag(resp)
    }

    func completeMultipart(_ key: String, uploadId: String, etags: [String]) async throws {
        var xml = "<CompleteMultipartUpload>"
        for (i, tag) in etags.enumerated() {
            xml += "<Part><PartNumber>\(i + 1)</PartNumber><ETag>&quot;\(tag)&quot;</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        let body = Data(xml.utf8)
        let req = makeRequest("POST", key: key, query: ["uploadId": uploadId], payloadHash: Self.sha256Hex(body))
        let (data, resp) = try await send(req, body: body)
        // S3 may answer 200 with an <Error> body for this call.
        if let text = String(data: data, encoding: .utf8), text.contains("<Error>") {
            throw Self.parseError(data, status: resp.statusCode)
        }
    }

    func abortMultipart(_ key: String, uploadId: String) async {
        _ = try? await send(makeRequest("DELETE", key: key, query: ["uploadId": uploadId]))
    }

    // MARK: Signing

    func makeRequest(_ method: String, key: String = "", query: [String: String] = [:],
                     headers: [String: String] = [:], payloadHash: String = S3Client.emptyHash,
                     date: Date = Date()) -> URLRequest {
        var path = "/" + Self.enc(bucket)
        if !key.isEmpty {
            path += "/" + key.split(separator: "/", omittingEmptySubsequences: false)
                .map { Self.enc(String($0)) }.joined(separator: "/")
        }
        let canonicalQuery = query.map { (Self.enc($0.key), Self.enc($0.value)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")

        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = port
        comps.percentEncodedPath = path
        if !canonicalQuery.isEmpty { comps.percentEncodedQuery = canonicalQuery }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = fmt.string(from: date)
        let day = String(amzDate.prefix(8))

        var all = headers
        all["Host"] = port.map { "\(host):\($0)" } ?? host
        all["x-amz-date"] = amzDate
        all["x-amz-content-sha256"] = payloadHash

        let sorted = all.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.0 < $1.0 }
        let canonicalHeaders = sorted.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = sorted.map(\.0).joined(separator: ";")

        let canonicalRequest = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amzDate, scope, Self.sha256Hex(Data(canonicalRequest.utf8))]
            .joined(separator: "\n")

        var k = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, "s3", "aws4_request"] { k = Self.hmac(k, part) }
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: k))
            .map { String(format: "%02x", $0) }.joined()

        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        for (name, value) in all where name != "Host" { req.setValue(value, forHTTPHeaderField: name) }
        req.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                     forHTTPHeaderField: "Authorization")
        return req
    }

    private func send(_ req: URLRequest, body: Data? = nil, file: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        let (data, resp): (Data, URLResponse)
        if let file {
            (data, resp) = try await Self.session.upload(for: req, fromFile: file)
        } else if let body {
            (data, resp) = try await Self.session.upload(for: req, from: body)
        } else {
            (data, resp) = try await Self.session.data(for: req)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw S3Error(status: 0, code: "InvalidResponse", message: "")
        }
        guard (200..<300).contains(http.statusCode) else { throw Self.parseError(data, status: http.statusCode) }
        return (data, http)
    }

    // MARK: Helpers

    private static func parseError(_ data: Data, status: Int) -> S3Error {
        let xml = XMLCollector.parse(data)
        let code = xml.first { $0.path.hasSuffix("Error/Code") }?.value
        let message = xml.first { $0.path.hasSuffix("Error/Message") }?.value
        return S3Error(status: status, code: code ?? HTTPURLResponse.localizedString(forStatusCode: status),
                       message: message ?? "")
    }

    private static func etag(_ resp: HTTPURLResponse) -> String {
        (resp.value(forHTTPHeaderField: "ETag") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: SymmetricKey, _ s: String) -> SymmetricKey {
        SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(s.utf8), using: key)))
    }

    /// RFC 3986 encoding as SigV4 requires: everything but unreserved characters.
    static func enc(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"),
                 UInt8(ascii: "."), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(b))
            default:
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }
}

/// Flattens an XML document into (element path, text) pairs.
final class XMLCollector: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var text = ""
    private var values: [(path: String, value: String)] = []

    static func parse(_ data: Data) -> [(path: String, value: String)] {
        let collector = XMLCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.values
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(name)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        values.append((stack.joined(separator: "/"), text))
        stack.removeLast()
        text = ""
    }
}
