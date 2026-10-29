import Foundation

// Progress tokens can span reads; retain only the current ASCII token.
struct CompressionProgressParser {
    private var boundary = true
    private var digits = 0
    private var value = 0
    mutating func consume(_ chunk: Data) -> Double? {
        var latest: Double?
        for byte in chunk {
            if byte >= 48 && byte <= 57, boundary || digits > 0 {
                if digits < 3 {
                    value = value * 10 + Int(byte - 48)
                    digits += 1
                } else {
                    digits = 0; value = 0
                }
                boundary = false
                continue
            }
            if byte == 37 && digits > 0 { latest = min(Double(value) / 100, 1) }
            digits = 0; value = 0
            boundary = byte == 8 || byte == 32 || (byte >= 9 && byte <= 13)
        }
        return latest
    }
}

// Decode only complete LF-delimited records so UTF-8 names survive split pipe reads.
// Non-path records are discarded as soon as their prefix is known.
struct ArchivePathParser {
    enum LineEnding { case lf, crlf }
    private let lineEnding: LineEnding
    init(lineEnding: LineEnding = .lf) { self.lineEnding = lineEnding }

    private var pending = Data()
    private var discarding = false
    private var paths: Set<String> = []
    private let prefix = Data("Path = ".utf8)

    mutating func consume(_ chunk: Data) {
        for byte in chunk {
            if byte == 10 {
                finishLine()
            } else if !discarding {
                pending.append(byte)
                if pending.count == prefix.count && pending != prefix {
                    pending.removeAll(keepingCapacity: true)
                    discarding = true
                }
            }
        }
    }
    private mutating func finishLine() {
        if !discarding, pending.starts(with: prefix) {
            // The bundled macOS engine emits LF; a trailing CR can belong to Icon\r.
            if lineEnding == .crlf && pending.last == 13 { pending.removeLast() }
            paths.insert(String(decoding: pending.dropFirst(prefix.count), as: UTF8.self))
        }
        pending.removeAll(keepingCapacity: true)
        discarding = false
    }
    mutating func finish() -> Set<String> {
        finishLine()
        return paths
    }
}

