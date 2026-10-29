import Foundation

public enum KkukError: LocalizedError {
    case inputMissing
    case differentInputLocations
    case systemRoot
    case unsupportedFileName(String)
    case unsupportedInput(String)
    case engineUnavailable
    case unsafeDestination
    case insufficientMemory
    case sourceChanged
    case archiveContentsMismatch(missing: [String], extra: [String])
    case engineFailed(status: Int32, details: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .inputMissing: return "압축할 파일이나 폴더를 선택해 주세요."
        case .differentInputLocations: return "같은 폴더 안의 항목을 선택해 주세요."
        case .systemRoot: return "시스템 루트 대신 압축할 파일이나 폴더를 선택해 주세요."
        case .unsupportedFileName(let name): return "줄바꿈이 포함된 파일 이름은 현재 지원하지 않습니다: \(name)"
        case .unsupportedInput(let path): return "일반 파일·폴더·심볼릭 링크만 압축할 수 있습니다: \(path)"
        case .engineUnavailable: return "7-Zip 엔진을 찾을 수 없습니다. 앱을 다시 빌드해 주세요."
        case .unsafeDestination: return "원본을 개인 폴더로 옮긴 뒤 다시 시도해 주세요."
        case .insufficientMemory: return "지금은 압축에 사용할 메모리 여유가 부족합니다. 다른 작업을 닫은 뒤 파일이나 폴더를 다시 선택해 주세요."
        case .sourceChanged: return "압축하는 동안 원본 파일이나 폴더가 변경됐습니다. 작업을 마친 뒤 다시 압축해 주세요."
        case .archiveContentsMismatch(let missing, let extra):
            return "압축 파일에 포함된 항목이 원본 목록과 다릅니다. 결과 파일을 확정하지 않았습니다.\n누락: \(missing.joined(separator: "\n"))\n추가: \(extra.joined(separator: "\n"))"
        case .engineFailed(let status, let details):
            let reason = status == 1 ? "일부 파일을 읽지 못했습니다." : "압축 엔진 작업에 실패했습니다."
            return "\(reason) (코드 \(status))\n\(details)"
        case .cancelled: return "압축을 취소했습니다."
        }
    }
}

