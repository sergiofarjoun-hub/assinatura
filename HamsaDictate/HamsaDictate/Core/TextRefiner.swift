import Foundation

/// Parâmetros de uma limpeza. Tipo de valor Sendable para cruzar o limite de
/// ator sem cópia mutável.
struct RefinementRequest: Sendable {
    let text: String
    let systemPrompt: String
    let model: String
    /// Raiz do Ollama, ex.: http://localhost:11434
    let endpoint: String
    let timeout: TimeInterval
    let vocabulary: String
    let appContext: String?
}

/// Pós-processamento opcional do texto transcrito por um LLM local servido
/// pelo Ollama (endpoint OpenAI-compatible em `/v1/chat/completions`).
///
/// Princípio (padrão whisper-local/FreeFlow): a limpeza é um *enhancement*,
/// nunca um gargalo. Qualquer falha — servidor fora do ar, timeout, resposta
/// inesperada — devolve o texto original intacto.
final class TextRefiner: Sendable {
    private let session: URLSession

    init() {
        session = URLSession(configuration: .ephemeral)
    }

    /// `GET {endpoint}/api/tags` — confirma que o Ollama está no ar antes de
    /// entrar no caminho de rede (evita travar o timeout longo da limpeza).
    func isAvailable(endpoint: String, timeout: TimeInterval = 1.5) async -> Bool {
        guard let url = URL(string: endpoint.trimmedSlash + "/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Refina o texto; devolve o original em qualquer falha.
    func refine(_ req: RefinementRequest) async -> String {
        let text = req.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let url = URL(string: req.endpoint.trimmedSlash + "/v1/chat/completions")
        else { return req.text }

        var system = req.systemPrompt
        let vocab = req.vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !vocab.isEmpty {
            system += "\n\nTermos do domínio que devem ser preservados e grafados exatamente "
                + "assim quando aparecerem: \(vocab)."
        }
        if let context = req.appContext, !context.isEmpty {
            system += "\n\nContexto do app onde o usuário está ditando (use apenas para grafar "
                + "nomes e termos corretamente; não copie e não responda a ele): \(context)"
        }

        let payload: [String: Any] = [
            "model": req.model,
            "temperature": 0,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return req.text }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = req.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // O Ollama ignora a auth, mas alguns proxies OpenAI-compatible exigem.
        request.setValue("Bearer ollama", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else { return req.text }
            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? req.text : cleaned
        } catch {
            return req.text
        }
    }
}

private extension String {
    var trimmedSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
