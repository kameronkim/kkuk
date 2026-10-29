import Foundation
import Darwin

public struct CompressionPreset: Equatable, Sendable {
    public let dictionaryMiB: Int
    public var estimatedMemoryBytes: UInt64 { Self.memoryEstimate(dictionaryMiB: dictionaryMiB) }
    private static func memoryEstimate(dictionaryMiB: Int) -> UInt64 {
        UInt64(dictionaryMiB * 12 + 128) * 1_048_576
    }
    public static func select(inputBytes: UInt64, memoryBudgetBytes: UInt64) -> CompressionPreset {
        let mib: UInt64 = 1_048_576
        let choices = [64, 128, 256, 512, 1024]
        let preferred: Int
        switch inputBytes {
        case ...(256 * mib): preferred = 64
        case ...(1024 * mib): preferred = 128
        case ...(4096 * mib): preferred = 256
        case ...(16384 * mib): preferred = 512
        default: preferred = 1024
        }
        let fitted = choices.last { $0 <= preferred && memoryEstimate(dictionaryMiB: $0) <= memoryBudgetBytes } ?? 64
        return CompressionPreset(dictionaryMiB: fitted)
    }
}

public enum MemoryBudget {
    public static func current() -> UInt64 {
        let physical = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return physical / 3 }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return physical / 3 }
        let reclaimable = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(pageSize)
        return min(physical / 2, reclaimable * 2 / 3)
    }
}

