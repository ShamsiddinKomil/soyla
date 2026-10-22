import Foundation
// `soyla models [--refresh]` : list transcription models with pricing.
public enum ModelsCLI {
    public static func run(args: [String]) async throws {
        let key = try Secrets.openRouterKey()
        let models = try await OpenRouterSTTProvider.listTranscriptionModels(apiKey: key, forceRefresh: args.contains("--refresh"))
        let w = max(models.map { $0.id.count }.max() ?? 10, 5)
        func pad(_ s: String, _ n: Int) -> String { s + String(repeating: " ", count: max(0, n - s.count)) }
        print(pad("id", w) + " | " + pad("prompt price", 14) + " | completion price")
        for m in models.sorted(by: { $0.id < $1.id }) {
            print(pad(m.id, w) + " | " + pad(m.promptPrice ?? "-", 14) + " | " + (m.completionPrice ?? "-"))
        }
        print("\(models.count) models")
    }
}
