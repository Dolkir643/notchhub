import Foundation
import Combine

@MainActor final class UpdateService: ObservableObject {
    @Published private(set) var message = ""
    @Published private(set) var isChecking = false
    @Published private(set) var releaseURL: URL?

    func check() {
        guard !isChecking else { return }
        isChecking = true
        message = "Проверяю…"
        releaseURL = nil
        Task {
            defer { isChecking = false }
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/Dolkir643/notchhub/releases/latest")!)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    URLSession.shared.dataTask(with: request) { data, response, error in
                        if let error { continuation.resume(throwing: error); return }
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                            continuation.resume(throwing: URLError(.badServerResponse)); return
                        }
                        continuation.resume(returning: data)
                    }.resume()
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3"
                if Self.isNewer(release.tag_name, than: current) {
                    message = "Доступна версия \(release.tag_name)"
                    releaseURL = URL(string: "https://github.com/Dolkir643/notchhub/releases/latest")
                } else { message = "Установлена актуальная версия" }
            } catch { message = "Не удалось проверить. Попробуйте позже." }
        }
    }
    private struct Release: Decodable { let tag_name: String }
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int]? {
            let clean = value.hasPrefix("v") ? String(value.dropFirst()) : value
            let chunks = clean.split(separator: ".", omittingEmptySubsequences: false)
            guard !chunks.isEmpty, chunks.allSatisfy({ Int($0) != nil }) else { return nil }
            return chunks.compactMap { Int($0) }
        }
        guard var a = parts(candidate), var b = parts(current) else { return false }
        let length = max(a.count, b.count)
        a += Array(repeating: 0, count: length - a.count)
        b += Array(repeating: 0, count: length - b.count)
        return b.lexicographicallyPrecedes(a)
    }
}
