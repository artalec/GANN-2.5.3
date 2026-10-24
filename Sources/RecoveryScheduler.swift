import Foundation

/// Планирует поиск замены для пропавших треков: один за раз, с нарастающим интервалом.
///
/// Защита от наложения: одновременно идёт не больше одного поиска. Следующая попытка
/// запускается через 1, 5, 15, 30 минут. Если поиск не нашёл файл, но отпечаток есть,
/// пробуем ещё. Если отпечатка нет, больше не ищем (трек надо перетащить заново).
@MainActor
final class RecoveryScheduler: ObservableObject {

    /// Трек, для которого сейчас идёт поиск (не больше одного).
    @Published private(set) var searchingTrackID: UUID?

    /// Статус каждого трека: сколько попыток было, когда следующая, последняя причина.
    struct Status {
        var attempts: Int = 0
        var nextAt: Date?
        var reason: String?
    }
    @Published private(set) var statuses: [UUID: Status] = [:]

    private let delays: [TimeInterval] = [60, 300, 900, 1800]
    private var task: Task<Void, Never>?

    /// Запускает поиск для всех пропавших треков из списка. Если поиск уже идёт, ничего не делает.
    func schedule(missingIDs: Set<UUID>, tracks: [UUID: (name: String, size: Int64?, hash: String?, path: String)]) {
        guard searchingTrackID == nil else { return }
        let now = Date()
        for id in missingIDs {
            guard let t = tracks[id] else { continue }
            if statuses[id]?.nextAt ?? .distantPast > now { continue }
            guard let size = t.size, let hash = t.hash else {
                statuses[id] = Status(attempts: 1, nextAt: nil, reason: "нет отпечатка")
                FileRecovery.log("«\(t.name)»: нет отпечатка — замена невозможна. Перетащите трек заново.")
                continue
            }
            startSearch(id: id, name: t.name, size: size, hash: hash, oldPath: t.path)
            return
        }
    }

    /// Принудительно запускает поиск для конкретного трека, если он пропал и не ищется сейчас.
    func forceSearch(id: UUID, name: String, size: Int64?, hash: String?, oldPath: String) {
        guard searchingTrackID == nil else { return }
        guard let s = size, let h = hash else {
            statuses[id] = Status(attempts: 1, nextAt: nil, reason: "нет отпечатка")
            FileRecovery.log("«\(name)»: нет отпечатка — замена невозможна.")
            return
        }
        startSearch(id: id, name: name, size: s, hash: h, oldPath: oldPath)
    }

    private func startSearch(id: UUID, name: String, size: Int64, hash: String, oldPath: String) {
        searchingTrackID = id
        let attempt = statuses[id]?.attempts ?? 0
        statuses[id] = Status(attempts: attempt + 1, nextAt: nil, reason: "идёт поиск")

        task?.cancel()
        task = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                FileRecovery.find(name: name, size: size, hash: hash, excluding: oldPath)
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.searchingTrackID = nil
                if let m = found {
                    self.statuses[id] = Status(attempts: 0, nextAt: nil, reason: "найден: \(m.url.path)")
                    NotificationCenter.default.post(name: .recoveryFoundReplacement,
                                                    object: nil,
                                                    userInfo: ["trackID": id, "url": m.url, "fingerprint": m.fingerprint])
                } else {
                    let next = Date().addingTimeInterval(self.delays[min(attempt, self.delays.count - 1)])
                    self.statuses[id] = Status(attempts: attempt + 1, nextAt: next, reason: "не найден, повтор через \(self.formatInterval(next.timeIntervalSinceNow))")
                }
            }
        }
    }

    private func formatInterval(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds)) с" }
        if seconds < 5400 { return "\(Int(seconds / 60)) мин" }
        return "\(Int(seconds / 3600)) ч"
    }
}

extension Notification.Name {
    static let recoveryFoundReplacement = Notification.Name("RecoveryFoundReplacement")
}
