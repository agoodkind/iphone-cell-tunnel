import Foundation

enum ToolError: Error, CustomStringConvertible {
    case failure(String)
    case usage(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        case .usage(let message):
            return message
        }
    }
}

struct CommandResult {
    let status: Int32
    let output: String
}
