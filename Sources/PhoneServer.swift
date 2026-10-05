import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Combine
import Darwin
import Foundation
import Network

@MainActor
final class PhoneServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var phoneURL: String?
    @Published private(set) var qrImage: NSImage?

    weak var model: AppModel?
    var regionPreviewData: Data?
    var hasRegionPreview: Bool { regionPreviewData != nil }
    var onReady: (() -> Void)?
    var onWaiting: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let port: NWEndpoint.Port = 8787
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let queue = DispatchQueue(label: "com.macielts.practice.phone-server")
    private var listener: NWListener?

    func start() throws {
        guard listener == nil else { return }
        guard let address = Self.localIPv4Address() else {
            throw PhoneServerError.noLocalAddress
        }
        let url = "http://\(address):\(port.rawValue)/?token=\(token)"
        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener
        phoneURL = url
        qrImage = Self.makeQR(for: url)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.onReady?()
                case .waiting(let error):
                    self.isRunning = false
                    self.onWaiting?(error.localizedDescription)
                case .failed(let error):
                    self.isRunning = false
                    self.listener = nil
                    self.onFailure?(error.localizedDescription)
                case .cancelled:
                    self.isRunning = false
                    self.listener = nil
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        phoneURL = nil
        qrImage = nil
        regionPreviewData = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                var requestData = accumulated
                if let data { requestData.append(data) }
                if let parsed = Self.parseRequest(requestData) {
                    self?.handle(parsed, on: connection)
                } else if isComplete || error != nil {
                    self?.send(status: 400, body: "Bad request", contentType: "text/plain; charset=utf-8", on: connection)
                } else {
                    self?.receiveRequest(on: connection, accumulated: requestData)
                }
            }
        }
    }

    private func handle(_ request: ParsedRequest, on connection: NWConnection) {
        guard authorize(request) else {
            send(status: 403, body: "Forbidden", contentType: "text/plain; charset=utf-8", on: connection)
            return
        }
        let components = URLComponents(string: "http://localhost\(request.path)")
        switch (request.method, components?.path ?? request.path) {
        case ("GET", "/"):
            guard let file = Bundle.main.url(forResource: "phone", withExtension: "html"),
                  let html = try? String(contentsOf: file, encoding: .utf8) else {
                send(status: 500, body: "Phone page is missing", contentType: "text/plain; charset=utf-8", on: connection)
                return
            }
            send(status: 200, body: html, contentType: "text/html; charset=utf-8", on: connection)
        case ("GET", "/api/state"):
            Task { @MainActor [weak self] in
                guard let self, let model = self.model else { return }
                let data = (try? JSONSerialization.data(withJSONObject: model.remoteState())) ?? Data("{}".utf8)
                self.send(status: 200, data: data, contentType: "application/json; charset=utf-8", on: connection)
            }
        case ("GET", "/api/region-preview"):
            if let regionPreviewData {
                send(status: 200, data: regionPreviewData, contentType: "image/jpeg", on: connection)
            } else {
                send(status: 404, body: "No image", contentType: "text/plain; charset=utf-8", on: connection)
            }
        case ("POST", "/api/region-preview"):
            Task { @MainActor [weak self] in self?.model?.remoteBeginRegionSelection() }
            send(status: 202, body: "{\"ok\":true}", contentType: "application/json; charset=utf-8", on: connection)
        case ("POST", "/api/region-cancel"):
            Task { @MainActor [weak self] in self?.model?.remoteCancelRegionSelection() }
            send(status: 202, body: "{\"ok\":true}", contentType: "application/json; charset=utf-8", on: connection)
        case ("POST", "/api/region"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Double]
            guard let payload,
                  let x = payload["x"], let y = payload["y"],
                  let width = payload["width"], let height = payload["height"] else {
                send(status: 400, body: "Invalid selection", contentType: "text/plain; charset=utf-8", on: connection)
                return
            }
            let region = CGRect(x: x, y: y, width: width, height: height)
            Task { @MainActor [weak self] in self?.model?.remoteSaveRegion(region) }
            send(status: 202, body: "{\"ok\":true}", contentType: "application/json; charset=utf-8", on: connection)
        case ("POST", "/api/scan"):
            Task { @MainActor [weak self] in self?.model?.remoteReadQuestion() }
            send(status: 202, body: "{\"ok\":true}", contentType: "application/json; charset=utf-8", on: connection)
        case ("POST", "/api/mode"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: String]
            let rawValue = payload?["mode"]
            Task { @MainActor [weak self] in
                if let rawValue { self?.model?.remoteSetResponseMode(rawValue) }
            }
            send(status: 202, body: "{\"ok\":true}", contentType: "application/json; charset=utf-8", on: connection)
        case ("POST", "/api/generate"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let editedQuestion = payload?["question"] as? String
            Task { @MainActor [weak self] in self?.model?.remoteGenerate(question: editedQuestion) }
            send(status: 202, body: "{\"ok\":true}", contentType: "application/json; charset=utf-8", on: connection)
        default:
            send(status: 404, body: "Not found", contentType: "text/plain; charset=utf-8", on: connection)
        }
    }

    private func authorize(_ request: ParsedRequest) -> Bool {
        if request.method == "GET", URLComponents(string: "http://localhost\(request.path)")?.path == "/" {
            return request.targetToken == token
        }
        return request.headers["x-token"] == token
    }

    private func send(status: Int, body: String, contentType: String, on connection: NWConnection) {
        send(status: status, data: Data(body.utf8), contentType: contentType, on: connection)
    }

    private func send(status: Int, data: Data, contentType: String, on connection: NWConnection) {
        let reason = status == 200 ? "OK" : (status == 202 ? "Accepted" : (status == 400 ? "Bad Request" : (status == 403 ? "Forbidden" : (status == 404 ? "Not Found" : "Error"))))
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(data.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func parseRequest(_ data: Data) -> ParsedRequest? {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator),
              let headerText = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let bodyStart = range.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let target = String(parts[1])
        let urlComponents = URLComponents(string: "http://localhost\(target)")
        let targetToken = urlComponents?.queryItems?.first(where: { $0.name == "token" })?.value
        return ParsedRequest(method: String(parts[0]), path: target, targetToken: targetToken, headers: headers, body: body)
    }

    private static func makeQR(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func localIPv4Address() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let value = String(cString: buffer)
                    if value != "127.0.0.1", interface.ifa_flags & UInt32(IFF_UP) != 0 {
                        if name == "en0" { return value }
                        if name.hasPrefix("en") { fallback = value }
                    }
                }
            }
            cursor = interface.ifa_next
        }
        return fallback
    }
}

private struct ParsedRequest {
    let method: String
    let path: String
    let targetToken: String?
    let headers: [String: String]
    let body: Data
}

enum PhoneServerError: Error {
    case noLocalAddress
}

extension PhoneServerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noLocalAddress:
            return "有効なWi-FiのIPv4アドレスが見つかりません。同じWi-Fiに接続しているか確認してください。"
        }
    }
}
