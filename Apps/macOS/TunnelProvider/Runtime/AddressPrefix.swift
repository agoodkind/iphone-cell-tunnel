import Foundation

enum AddressFamily: String, Sendable {
    case ipv4
    case ipv6
}

struct AddressPrefix: Sendable, Equatable {
    let family: AddressFamily
    let address: String
    let prefixLength: Int
}
