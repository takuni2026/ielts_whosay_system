import Foundation

enum OllamaError: Error {
    case modelUnavailable
    case badResponse(String)
    case emptyResponse
}

enum ResponseMode: String, CaseIterable, Identifiable {
    case ieltsEnglish
    case japaneseQuiz

    var id: String { rawValue }
    var title: String { self == .ieltsEnglish ? "IELTS英語" : "日本語クイズ" }
    var answerTitle: String { self == .ieltsEnglish ? "C1レベルの回答例" : "答えと解説" }
    var ocrLanguages: [String] { self == .ieltsEnglish ? ["en-US"] : ["ja-JP", "en-US"] }

    var systemPrompt: String {
        switch self {
        case .ieltsEnglish:
            return "You are an IELTS English speaking coach. Write one polished model answer to the user's prompt in natural, fluent C1-level spoken English. Aim for about 190–220 words, substantial enough to speak for roughly one to two minutes. Answer the question directly, develop two or three specific points with concrete details or a brief personal-sounding example, and end naturally. Use varied vocabulary and complex but clear sentence structures. Sound thoughtful and authentic rather than formal or memorised. Return only the answer itself, with no title, word count, explanations, or quotation marks. Never invent personal facts about the learner; use a plausible first-person illustrative answer where helpful."
        case .japaneseQuiz:
            return "あなたは学習者のための日本語クイズ解説者です。問題文が日本語でも英語でも、回答と解説は日本語で書いてください。選択肢問題では、問題文とすべての選択肢を注意深く読み、冒頭に正解の記号と選択肢を明示してください。続けて根拠を分かりやすく説明し、情報が十分なら他の選択肢が誤りである理由も簡潔に説明してください。『複数選択』などの指示があれば従い、単一選択と決めつけないでください。選択肢がない問題は、答えを先に述べてから学習に役立つ説明を付けてください。問題の情報が不足している、または正解を確定できない場合は、推測で断定せず、その旨を説明してください。長くなりすぎない自然な日本語にし、最終回答だけを出してください。"
        }
    }

    var tokenLimit: Int { self == .ieltsEnglish ? 420 : 520 }
}

struct OllamaService {
    static let modelName = "qwen3.5:4b"
    private let baseURL = URL(string: "http://127.0.0.1:11434")!

    func isAvailable() async throws -> Bool {
        let url = baseURL.appending(path: "/api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaError.badResponse("Ollama APIから正常な応答がありませんでした。")
        }
        let payload = try JSONDecoder().decode(TagsResponse.self, from: data)
        return payload.models.contains { $0.name == Self.modelName || $0.name.hasPrefix(Self.modelName + "-") }
    }

    func warmModel() async throws {
        let url = baseURL.appending(path: "/api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.modelName,
            "prompt": " ",
            "stream": false,
            "keep_alive": "15m",
            "options": ["num_predict": 0]
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaError.badResponse("モデルをメモリに準備できませんでした。")
        }
    }

    func generateAnswer(for question: String, mode: ResponseMode, onChunk: @MainActor @Sendable (String) -> Void) async throws {
        let url = baseURL.appending(path: "/api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.modelName,
            "think": false,
            "stream": true,
            "keep_alive": "15m",
            "options": [
                "temperature": mode == .ieltsEnglish ? 0.55 : 0.25,
                "num_predict": mode.tokenLimit,
                "num_ctx": 4096
            ],
            "messages": [
                ["role": "system", "content": mode.systemPrompt],
                ["role": "user", "content": question]
            ]
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.badResponse("OllamaからHTTP応答がありませんでした。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let description = http.statusCode == 404
                ? "Ollamaが \(Self.modelName) を見つけられませんでした。モデル名を確認してください。"
                : "Ollama APIエラー（HTTP \(http.statusCode)）。"
            throw OllamaError.badResponse(description)
        }

        var receivedText = false
        var receivedThinkingOnly = false
        for try await line in bytes.lines {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if let error = event["error"] as? String {
                throw OllamaError.badResponse(error)
            }
            if let message = event["message"] as? [String: Any] {
                if let thinking = message["thinking"] as? String, !thinking.isEmpty {
                    receivedThinkingOnly = true
                }
                if let content = message["content"] as? String, !content.isEmpty {
                    receivedText = true
                    await onChunk(content)
                }
            }
        }
        guard receivedText else {
            if receivedThinkingOnly {
                throw OllamaError.badResponse("Ollamaから思考欄のみが返り、回答欄は空でした。think=false を送信しましたが反映されていません。Ollamaを更新し、再度お試しください。")
            }
            throw OllamaError.emptyResponse
        }
    }
}

private struct TagsResponse: Decodable {
    struct Model: Decodable {
        let name: String
    }
    let models: [Model]
}
