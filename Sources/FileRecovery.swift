import Foundation

/// Поиск пропавшего файла трека по всему компьютеру.
///
/// Порядок: Spotlight, привычные папки (Музыка, Загрузки, Документы, Рабочий стол,
/// iCloud Drive), внешние диски, остальное. Прекращается на первом совпадении.
/// Каждый шаг пишется в файл `~/Library/Application Support/DJPlayer/recovery.log`.
enum FileRecovery {

    struct Match {
        let url: URL
        let fingerprint: FileFingerprint
    }

    /// Файл журнала. Создаётся при первой записи.
    private static var logFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("DJPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recovery.log")
    }

    static func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        NSLog("DJPlayer recovery: %@", message)
        if let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else if let data = line.data(using: .utf8) {
            try? data.write(to: logFile)
        }
    }

    /// macOS может хранить одно и то же имя в разных Unicode-формах.
    static func normalized(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
    }

    /// Корзина, системные каталоги и служебные места.
    private static func skipped(_ path: String) -> Bool {
        let exclude = ["/.Trash/", "/.Trashes/", "/System/", "/private/", "/usr/", "/bin/", "/sbin/",
                       "/dev/", "/cores/", "/var/", "/Library/", "/node_modules/", "/.git/",
                       "/Library/Caches/", "/Backups.backupdb/"]
        return exclude.contains(where: { path.contains($0) })
    }

    static func find(name: String, size: Int64, hash: String, excluding oldPath: String) -> Match? {
        let started = Date()
        let target = normalized(name)
        log("ищу «\(name)» (\(size) байт), старый путь: \(oldPath)")

        // 1. Spotlight: быстрее всего, если индекс включён.
        let spot = spotlightMatches(name: name)
        log("Spotlight: кандидатов по имени — \(spot.count)")
        if let m = check(spot, target: target, size: size, hash: hash, excluding: oldPath) {
            return m
        }

        // 2. Привычные места: Музыка, Загрузки, Документы, Рабочий стол, iCloud Drive.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let common = [
            home.appendingPathComponent("Music"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        ]
        for root in common where FileManager.default.fileExists(atPath: root.path) {
            let cands = walk(root, target: target, limit: 50000)
            log("\(root.lastPathComponent): просмотрено \(cands.walked), совпало по имени — \(cands.matches.count)")
            if let m = check(cands.matches, target: target, size: size, hash: hash, excluding: oldPath) {
                return m
            }
        }

        // 3. Внешние диски в /Volumes.
        let volumes = URL(fileURLWithPath: "/Volumes")
        if let mounted = try? FileManager.default.contentsOfDirectory(at: volumes, includingPropertiesForKeys: nil) {
            for vol in mounted {
                let cands = walk(vol, target: target, limit: 100000)
                log("\(vol.lastPathComponent): просмотрено \(cands.walked), совпало — \(cands.matches.count)")
                if let m = check(cands.matches, target: target, size: size, hash: hash, excluding: oldPath) {
                    return m
                }
            }
        }

        // 4. Остальное (редко, но бывает: /Users/Shared, другие пользователи с доступом).
        let rest = walk(URL(fileURLWithPath: "/"), target: target, limit: 200000)
        log("остальной диск: просмотрено \(rest.walked), совпало — \(rest.matches.count)")
        if let m = check(rest.matches, target: target, size: size, hash: hash, excluding: oldPath) {
            return m
        }

        let seconds = Date().timeIntervalSince(started)
        log("поиск завершён за \(String(format: "%.1f", seconds)) с, совпадений по хэшу нет")
        return nil
    }

    /// Обходит дерево и собирает файлы с нужным именем. Останавливается по лимиту.
    private static func walk(_ root: URL, target: String, limit: Int) -> (matches: [URL], walked: Int) {
        var matches: [URL] = []
        var walked = 0
        guard let en = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else { return ([], 0) }
        for case let url as URL in en {
            if walked >= limit { break }
            if skipped(url.path) { en.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            walked += 1
            if normalized(url.lastPathComponent) == target { matches.append(url) }
        }
        return (matches, walked)
    }

    /// Проверяет кандидатов: размер → хэш. Хэш считаем только при совпадении размера.
    private static func check(_ urls: [URL], target: String, size: Int64, hash: String,
                              excluding oldPath: String) -> Match? {
        for url in urls {
            guard url.path != oldPath, normalized(url.lastPathComponent) == target else { continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let s = attrs[.size] as? NSNumber else { continue }
            guard s.int64Value == size else {
                log("«\(url.path)»: размер другой (\(s.int64Value) ≠ \(size))")
                continue
            }
            guard let fp = FileFingerprint.compute(path: url.path) else {
                log("«\(url.path)»: не удалось прочитать файл")
                continue
            }
            if fp.sha256 == hash {
                log("✓ совпадение по хэшу: \(url.path)")
                return Match(url: url, fingerprint: fp)
            }
            log("«\(url.path)»: размер совпал, хэш другой")
        }
        return nil
    }

    /// Кандидаты по имени через Spotlight.
    private static func spotlightMatches(name: String) -> [URL] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-name", name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { log("mdfind: \(error.localizedDescription)"); return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 { log("mdfind: код завершения \(p.terminationStatus)") }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
    }
}
