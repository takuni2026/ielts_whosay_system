import AppKit
import Combine
import Foundation
import ScreenCaptureKit
import Vision

@MainActor
final class AppModel: ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var responseMode: ResponseMode = .ieltsEnglish {
        didSet { UserDefaults.standard.set(responseMode.rawValue, forKey: "responseMode") }
    }
    @Published var status = "Ollamaを確認しています…"
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var isGenerating = false
    @Published var isCheckingOllama = false
    @Published var hasOllama = false
    @Published var screenPermissionMissing = false
    @Published var region: CGRect?
    @Published var regionPreview: NSImage?
    @Published var showRegionPicker = false

    let phoneServer = PhoneServer()
    private let captureService = ScreenCaptureService()
    private let ollama = OllamaService()

    var wordCount: Int {
        answer.split(whereSeparator: \.isWhitespace).count
    }

    var answerMetric: String {
        responseMode == .ieltsEnglish
            ? "約\(wordCount)語"
            : "約\(answer.filter { !$0.isWhitespace }.count)字"
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "questionRegion") {
            let parsed = NSRectFromString(saved)
            if !parsed.isNull, parsed.width > 0, parsed.height > 0 {
                region = parsed
            }
        }
        if let savedMode = UserDefaults.standard.string(forKey: "responseMode"),
           let parsedMode = ResponseMode(rawValue: savedMode) {
            responseMode = parsedMode
        }
        phoneServer.model = self
        phoneServer.onReady = { [weak self] in
            self?.status = "iPhone操作のQRコードを表示しています。"
            self?.errorMessage = nil
        }
        phoneServer.onWaiting = { [weak self] reason in
            self?.status = "iPhone接続の許可を待っています…"
            self?.errorMessage = "ローカルネットワークの確認が表示されたら許可してください。\n\(reason)"
        }
        phoneServer.onFailure = { [weak self] reason in
            self?.status = "iPhone操作サーバーを開始できませんでした"
            self?.errorMessage = "ポート8787を使用できないか、macOSが接続を拒否しました。\n\(reason)"
        }
        checkOllama()
    }

    func selectQuestionRegion() {
        errorMessage = nil
        screenPermissionMissing = false
        status = "画面を撮影しています…"
        Task {
            do {
                let image = try await captureService.captureDisplay()
                screenPermissionMissing = false
                regionPreview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                showRegionPicker = true
                status = "質問の範囲を選択してください"
            } catch {
                status = "画面を撮影できません"
                screenPermissionMissing = isScreenPermissionError(error)
                errorMessage = captureErrorDescription(error)
            }
        }
    }

    func setRegion(_ normalizedRegion: CGRect) {
        let safe = normalizedRegion.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard safe.width > 0.01, safe.height > 0.01 else { return }
        region = safe
        UserDefaults.standard.set(NSStringFromRect(safe), forKey: "questionRegion")
        status = "範囲を保存しました。次の質問を読み取れます。"
    }

    func readQuestion() {
        guard let region else {
            errorMessage = "先に画面上の質問範囲を指定してください。"
            return
        }
        guard !isBusy else { return }
        isBusy = true
        isGenerating = false
        answer = ""
        errorMessage = nil
        status = "画面から質問を読み取っています…"
        Task {
            defer { isBusy = false }
            do {
                let image = try await captureService.captureDisplay()
                let text = try await captureService.recognizeText(in: image, region: region, languages: responseMode.ocrLanguages)
                screenPermissionMissing = false
                question = text
                status = text.isEmpty
                    ? "文字が見つかりませんでした。範囲を調整して再試行してください。"
                    : "質問を読み取りました。内容を確認し、OKを押してください。"
                if text.isEmpty { errorMessage = "選択範囲に文字を認識できませんでした。範囲を調整してください。" }
            } catch {
                status = "質問を読み取れませんでした"
                screenPermissionMissing = isScreenPermissionError(error)
                errorMessage = captureErrorDescription(error)
            }
        }
    }

    func handleAutomationURL(_ url: URL) {
        guard url.scheme == "ieltspractice" else { return }
        switch (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased() {
        case "read-question", "scan":
            readQuestion()
        case "japanese-quiz":
            let requestID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "requestID" })?
                .value
                .flatMap { UUID(uuidString: $0) }
            readAndAnswerJapaneseQuiz(requestID: requestID)
        case "generate":
            generateAnswer()
        default:
            errorMessage = "不明なAppleScript操作です: \(url.absoluteString)"
        }
    }

    func readAndAnswerJapaneseQuiz(requestID: UUID? = nil) {
        guard !isBusy else {
            let message = "別の処理が終わってから、もう一度実行してください。"
            errorMessage = message
            writeAutomationResult(requestID: requestID, succeeded: false, text: message)
            return
        }
        responseMode = .japaneseQuiz
        guard let region else {
            let message = "先にMacアプリで質問範囲を指定してください。"
            errorMessage = message
            writeAutomationResult(requestID: requestID, succeeded: false, text: message)
            return
        }

        isBusy = true
        isGenerating = false
        question = ""
        answer = ""
        errorMessage = nil
        screenPermissionMissing = false
        status = "保存済みの範囲から日本語クイズを読み取っています…"
        Task {
            defer {
                isBusy = false
                isGenerating = false
            }
            do {
                let image = try await captureService.captureDisplay()
                let recognizedQuestion = try await captureService.recognizeText(
                    in: image,
                    region: region,
                    languages: ResponseMode.japaneseQuiz.ocrLanguages
                )
                question = recognizedQuestion
                screenPermissionMissing = false
                isGenerating = true
                status = "問題を読み取りました。日本語で答えと解説を生成しています…"
                try await streamAnswer(for: recognizedQuestion, mode: .japaneseQuiz)
                status = "答えと解説ができました。"
                let firstSentence = Self.firstSentence(in: answer)
                if firstSentence.isEmpty {
                    let message = "回答は生成されましたが、最初の一文を取り出せませんでした。"
                    errorMessage = message
                    writeAutomationResult(requestID: requestID, succeeded: false, text: message)
                } else {
                    writeAutomationResult(requestID: requestID, succeeded: true, text: firstSentence)
                }
            } catch {
                if isGenerating {
                    status = "回答を生成できませんでした"
                    errorMessage = ollamaErrorDescription(error)
                } else {
                    status = "質問を読み取れませんでした"
                    screenPermissionMissing = isScreenPermissionError(error)
                    errorMessage = captureErrorDescription(error)
                }
                writeAutomationResult(requestID: requestID, succeeded: false, text: errorMessage ?? "処理できませんでした。")
            }
        }
    }

    func generateAnswer() {
        let cleanedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuestion.isEmpty, !isBusy else { return }
        question = cleanedQuestion
        answer = ""
        errorMessage = nil
        isBusy = true
        isGenerating = true
        let selectedMode = responseMode
        status = selectedMode == .ieltsEnglish ? "英語の回答例を生成しています…" : "日本語の答えと解説を生成しています…"
        Task {
            defer {
                isBusy = false
                isGenerating = false
            }
            do {
                try await streamAnswer(for: cleanedQuestion, mode: selectedMode)
                status = selectedMode == .ieltsEnglish ? "回答ができました。声に出して練習してみてください。" : "答えと解説ができました。"
            } catch {
                status = "回答を生成できませんでした"
                errorMessage = ollamaErrorDescription(error)
            }
        }
    }

    private func streamAnswer(for question: String, mode: ResponseMode) async throws {
        answer = ""
        try await ollama.generateAnswer(for: question, mode: mode) { [weak self] chunk in
            self?.answer += chunk
        }
    }

    private func writeAutomationResult(requestID: UUID?, succeeded: Bool, text: String) {
        guard let requestID,
              let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let directory = applicationSupport
            .appendingPathComponent("com.macielts.practice", isDirectory: true)
            .appendingPathComponent("automation", isDirectory: true)
        let file = directory.appendingPathComponent("\(requestID.uuidString).txt")
        let singleLine = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let contents = "\(succeeded ? "OK" : "ERROR")\n\(singleLine)"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file, options: .atomic)
        } catch {
            status = "AppleScriptへ回答を返せませんでした"
            errorMessage = "回答はアプリに表示されていますが、連携用ファイルを書き込めませんでした。\n\(error.localizedDescription)"
        }
    }

    private static func firstSentence(in text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r", with: "")
        let punctuation = normalized.firstIndex { "。！？!?".contains($0) }
        let newline = normalized.firstIndex(of: "\n")
        let end = [punctuation, newline].compactMap { $0 }.min() ?? normalized.endIndex
        return String(normalized[..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_` "))
    }

    func startPhoneControl() {
        guard !phoneServer.isRunning else { return }
        do {
            try phoneServer.start()
            status = "iPhone操作サーバーを起動しています…"
            errorMessage = nil
        } catch {
            status = "iPhone操作サーバーを開始できませんでした"
            errorMessage = error.localizedDescription
        }
    }

    func stopPhoneControl() {
        phoneServer.stop()
        status = "iPhone操作サーバーを停止しました"
    }

    func remoteState() -> [String: Any] {
        var state: [String: Any] = [
            "question": question,
            "answer": answer,
            "status": status,
            "busy": isBusy,
            "generating": isGenerating,
            "error": errorMessage ?? "",
            "wordCount": wordCount,
            "answerMetric": answerMetric,
            "responseMode": responseMode.rawValue,
            "responseModeTitle": responseMode.title,
            "hasRegionPreview": phoneServer.hasRegionPreview
        ]
        if let region {
            state["region"] = [region.minX, region.minY, region.width, region.height]
        }
        return state
    }

    func remoteReadQuestion() {
        readQuestion()
    }

    func remoteSetResponseMode(_ rawValue: String) {
        guard !isBusy, let mode = ResponseMode(rawValue: rawValue) else { return }
        responseMode = mode
        status = mode == .ieltsEnglish ? "IELTS英語モードです。質問を読み取れます。" : "日本語クイズモードです。選択肢にも対応します。"
    }

    func remoteBeginRegionSelection() {
        errorMessage = nil
        status = "範囲選択用の画面を撮影しています…"
        Task {
            do {
                let image = try await captureService.captureDisplay()
                screenPermissionMissing = false
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
                    throw ScreenCaptureError.noDisplay
                }
                phoneServer.regionPreviewData = data
                status = "iPhoneで質問の範囲を囲み、保存してください。"
            } catch {
                status = "範囲選択用の画面を撮影できませんでした"
                screenPermissionMissing = isScreenPermissionError(error)
                errorMessage = captureErrorDescription(error)
            }
        }
    }

    func remoteSaveRegion(_ normalizedRegion: CGRect) {
        setRegion(normalizedRegion)
        phoneServer.regionPreviewData = nil
    }

    func remoteCancelRegionSelection() {
        phoneServer.regionPreviewData = nil
    }

    func remoteGenerate(question editedQuestion: String?) {
        if let editedQuestion, !editedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            question = editedQuestion
        }
        generateAnswer()
    }

    func checkOllama() {
        guard !isCheckingOllama else { return }
        isCheckingOllama = true
        Task { await performOllamaCheck() }
    }

    private func performOllamaCheck() async {
        defer { isCheckingOllama = false }
        do {
            let isAvailable = try await ollama.isAvailable()
            hasOllama = isAvailable
            if isAvailable {
                status = "モデルをメモリに準備しています（最初は少し時間がかかります）…"
                do { try await ollama.warmModel() } catch { /* Warm-up is optional; answer generation reports actionable errors. */ }
                status = "Ollama接続済み（\(OllamaService.modelName)）。質問範囲を指定して始めてください。"
            } else {
                status = "Ollamaは起動していますが、\(OllamaService.modelName) が見つかりません。"
                errorMessage = "Ollamaで \(OllamaService.modelName) を利用できるか確認してください。"
            }
        } catch {
            hasOllama = false
            status = "Ollamaに接続できません"
            errorMessage = "Ollamaを起動してから再起動してください（通常は ollama serve）。\n\(error.localizedDescription)"
        }
    }

    private func captureErrorDescription(_ error: Error) -> String {
        if let captureError = error as? ScreenCaptureError {
            switch captureError {
            case .noDisplay: return "表示中のディスプレイが見つかりませんでした。"
            case .invalidRegion: return "指定範囲が無効です。画面範囲を選び直してください。"
            case .emptyOCR: return "選択範囲から文字を読み取れませんでした。範囲を調整してください。"
            case .permissionNotGranted:
                return "このアプリ自身に画面収録の許可が必要です。Chromeのカメラ・マイク許可とは別の設定です。「システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオ収録」で IELTS Speaking Practice を許可し、設定を変えた後はアプリを完全終了して再起動してください。"
            }
        }
        let detail = error as NSError
        return "画面を取得できませんでした（\(detail.domain), code \(detail.code)）。このアプリの「画面とシステムオーディオ収録」権限を確認し、変更後ならアプリを完全終了して再起動してください。"
    }

    private func isScreenPermissionError(_ error: Error) -> Bool {
        guard let captureError = error as? ScreenCaptureError else { return false }
        if case .permissionNotGranted = captureError { return true }
        return false
    }

    private func ollamaErrorDescription(_ error: Error) -> String {
        if let ollamaError = error as? OllamaError {
            switch ollamaError {
            case .modelUnavailable: return "\(OllamaService.modelName) が見つかりません。Ollamaでモデル名を確認してください。"
            case .badResponse(let message): return message
            case .emptyResponse: return "Ollamaから回答テキストが返りませんでした。Qwen3.5では思考モードを無効にして再要求しています。Ollamaが最新か確認して、もう一度お試しください。"
            }
        }
        return "Ollamaが起動中か確認してください。\n\(error.localizedDescription)"
    }
}

enum ScreenCaptureError: Error {
    case noDisplay
    case invalidRegion
    case emptyOCR
    case permissionNotGranted
}

struct ScreenCaptureService {
    func captureDisplay() async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw ScreenCaptureError.permissionNotGranted
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ScreenCaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    func recognizeText(in image: CGImage, region: CGRect, languages: [String]) async throws -> String {
        let bounded = region.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard bounded.width > 0.01, bounded.height > 0.01 else {
            throw ScreenCaptureError.invalidRegion
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        // Vision's normalized region uses a lower-left origin; the picker uses a top-left origin.
        request.regionOfInterest = CGRect(x: bounded.minX,
                                          y: 1 - bounded.maxY,
                                          width: bounded.width,
                                          height: bounded.height)
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        let lines = (request.results ?? [])
            .sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.012 {
                    return $0.boundingBox.midY > $1.boundingBox.midY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw ScreenCaptureError.emptyOCR }
        return result
    }
}
