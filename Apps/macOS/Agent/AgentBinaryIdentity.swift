//
//  AgentBinaryIdentity.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-06-06.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import CryptoKit
import Foundation
import MachO

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - AgentBinaryIdentity

/// Reports the running agent's own identity so a reinstall can confirm the freshly
/// built binary is the one answering, not a stale agent registered from another
/// bundle path. The build UUID is the Mach-O `LC_UUID`, which changes per link and
/// survives re-signing; the SHA-256 pins the exact on-disk file.
enum AgentBinaryIdentity {
  static func executablePath() -> String {
    Bundle.main.executableURL?.standardizedFileURL.path
      ?? CommandLine.arguments.first
      ?? ""
  }

  static func buildUUID() -> String? {
    for index in 0..<_dyld_image_count() {
      guard let header = _dyld_get_image_header(index) else {
        continue
      }
      if header.pointee.filetype != UInt32(MH_EXECUTE) {
        continue
      }
      return buildUUID(fromMachHeader: header)
    }
    return nil
  }

  private static func buildUUID(fromMachHeader header: UnsafePointer<mach_header>) -> String? {
    let is64Bit =
      header.pointee.magic == MH_MAGIC_64 || header.pointee.magic == MH_CIGAM_64
    let headerSize =
      is64Bit ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
    var cursor = UnsafeRawPointer(header).advanced(by: headerSize)
    for _ in 0..<Int(header.pointee.ncmds) {
      let command = cursor.assumingMemoryBound(to: load_command.self)
      if command.pointee.cmd == UInt32(LC_UUID) {
        let uuidCommand = cursor.assumingMemoryBound(to: uuid_command.self)
        return UUID(uuid: uuidCommand.pointee.uuid).uuidString
      }
      cursor = cursor.advanced(by: Int(command.pointee.cmdsize))
    }
    return nil
  }

  static func sha256() -> String? {
    guard let executableURL = Bundle.main.executableURL else {
      return nil
    }
    do {
      let data = try Data(contentsOf: executableURL)
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    } catch {
      logger.error(
        """
        agent identity sha256 read failed \
        details=\(error.localizedDescription, privacy: .public) recovery=return-nil
        """
      )
      return nil
    }
  }
}
