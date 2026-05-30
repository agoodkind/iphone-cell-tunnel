import Foundation

struct XcodeDevice: Decodable {
    let simulator: Bool
    let available: Bool
    let platform: String
    let identifier: String
    let name: String
}
