//
//  ProcessSupport.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

/// Namesake type so SwiftLint `file_name` matches `ProcessSupport.swift`.
enum ProcessSupport {}

private let logger = CellTunnelLog.logger(category: .build)
private let commandNotFoundExitStatus: Int32 = 127

func writePrefixedLines(_ text: String, prefix: String) {
  guard !text.isEmpty else {
    return
  }
  var remainder = text
  if remainder.hasSuffix("\n") {
    remainder.removeLast()
  }
  for line in remainder.split(separator: "\n", omittingEmptySubsequences: false) {
    FileHandle.standardOutput.write(Data("\(prefix)\(line)\n".utf8))
  }
}

// MARK: - PrefixedProcess

/// A long-running process whose stdout/stderr lines are forwarded with a prefix.
/// Call `waitUntilExitAndDrain()` so the final pipe contents are not lost.
final class PrefixedProcess: @unchecked Sendable {
  let process: Process
  private let queue: DispatchQueue
  private let stdoutState: PrefixedLineBuffer
  private let stderrState: PrefixedLineBuffer
  private let stdoutEOF: DispatchSemaphore
  private let stderrEOF: DispatchSemaphore

  private struct Parts {
    var process: Process
    var queue: DispatchQueue
    var stdoutState: PrefixedLineBuffer
    var stderrState: PrefixedLineBuffer
    var stdoutEOF: DispatchSemaphore
    var stderrEOF: DispatchSemaphore
  }

  private init(parts: Parts) {
    self.process = parts.process
    self.queue = parts.queue
    self.stdoutState = parts.stdoutState
    self.stderrState = parts.stderrState
    self.stdoutEOF = parts.stdoutEOF
    self.stderrEOF = parts.stderrEOF
  }

  static func start(
    executable: String,
    arguments: [String],
    linePrefix: String,
    environment: [String: String] = [:],
    workingDirectory: URL = repoRoot
  ) throws -> PrefixedProcess {
    logger.debug(
      "startPrefixedProcess executable=\(executable, privacy: .public) prefix=\(linePrefix, privacy: .public)"
    )
    let launched = Process()
    launched.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    launched.arguments = [executable] + arguments
    launched.currentDirectoryURL = workingDirectory
    launched.environment = mergedEnvironment(environment)

    let outPipe = Pipe()
    let errPipe = Pipe()
    launched.standardOutput = outPipe
    launched.standardError = errPipe

    let lineQueue = DispatchQueue(label: "celltunnel.prefixed-process.\(executable)")
    let outBuffer = PrefixedLineBuffer(prefix: linePrefix)
    let errBuffer = PrefixedLineBuffer(prefix: linePrefix)
    let stdoutEndOfFile = DispatchSemaphore(value: 0)
    let stderrEndOfFile = DispatchSemaphore(value: 0)

    // Appends and EOF signals share lineQueue so waitUntilExitAndDrain can flush only
    // after every in-flight append has finished (no post-flush tail loss).
    outPipe.fileHandleForReading.readabilityHandler = { handle in
      Self.handleReadable(
        handle: handle,
        buffer: outBuffer,
        queue: lineQueue,
        eof: stdoutEndOfFile
      )
    }
    errPipe.fileHandleForReading.readabilityHandler = { handle in
      Self.handleReadable(
        handle: handle,
        buffer: errBuffer,
        queue: lineQueue,
        eof: stderrEndOfFile
      )
    }

    try launched.run()
    return PrefixedProcess(
      parts: Parts(
        process: launched,
        queue: lineQueue,
        stdoutState: outBuffer,
        stderrState: errBuffer,
        stdoutEOF: stdoutEndOfFile,
        stderrEOF: stderrEndOfFile
      )
    )
  }

  private static func handleReadable(
    handle: FileHandle,
    buffer: PrefixedLineBuffer,
    queue: DispatchQueue,
    eof: DispatchSemaphore
  ) {
    // Capture bytes before hopping to lineQueue so EOF and appends for this handle
    // stay in the order Foundation delivered them.
    let data = handle.availableData
    queue.async {
      if data.isEmpty {
        handle.readabilityHandler = nil
        eof.signal()
        return
      }
      buffer.append(data)
    }
  }

  var isRunning: Bool {
    process.isRunning
  }

  var terminationStatus: Int32 {
    process.terminationStatus
  }

  func terminate() {
    guard process.isRunning else {
      return
    }
    process.terminate()
  }

  func waitUntilExitAndDrain() {
    process.waitUntilExit()
    stdoutEOF.wait()
    stderrEOF.wait()
    queue.sync {
      stdoutState.flushRemainder()
      stderrState.flushRemainder()
    }
  }
}

/// Starts a long-running process and forwards each complete stdout/stderr line with a
/// prefix. The caller owns lifetime and must wait or terminate the returned handle.
func startPrefixedProcess(
  executable: String,
  arguments: [String],
  linePrefix: String,
  environment: [String: String] = [:],
  workingDirectory: URL = repoRoot
) throws -> PrefixedProcess {
  try PrefixedProcess.start(
    executable: executable,
    arguments: arguments,
    linePrefix: linePrefix,
    environment: environment,
    workingDirectory: workingDirectory
  )
}

// MARK: - PrefixedLineBuffer

final class PrefixedLineBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let prefix: String

  init(prefix: String) {
    self.prefix = prefix
  }

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    buffer.append(data)
    while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
      let lineData = buffer.subdata(in: buffer.startIndex..<newline)
      buffer.removeSubrange(buffer.startIndex...newline)
      let line = String(data: lineData, encoding: .utf8) ?? ""
      FileHandle.standardOutput.write(Data("\(prefix)\(line)\n".utf8))
    }
  }

  func flushRemainder() {
    lock.lock()
    defer { lock.unlock() }
    guard !buffer.isEmpty else {
      return
    }
    let line = String(data: buffer, encoding: .utf8) ?? ""
    buffer.removeAll(keepingCapacity: false)
    FileHandle.standardOutput.write(Data("\(prefix)\(line)\n".utf8))
  }
}

// MARK: - CancellationFlag

final class CancellationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}

func run(
  _ executable: String,
  _ arguments: [String],
  environment: [String: String] = [:],
  workingDirectory: URL = repoRoot,
  failureMessage: String? = nil,
  processRegistry: ProcessRegistry? = nil
) throws {
  logger.debug("run executable=\(executable, privacy: .public)")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + arguments
  process.currentDirectoryURL = workingDirectory
  process.environment = mergedEnvironment(environment)

  processRegistry?.add(process)
  defer { processRegistry?.remove(process) }

  try process.run()
  processRegistry?.noteRunning(process)
  process.waitUntilExit()

  guard process.terminationStatus == 0 else {
    let renderedCommand = failureMessage ?? ([executable] + arguments).joined(separator: " ")
    throw ToolError.failure(
      "\(renderedCommand) failed with status \(process.terminationStatus)")
  }
}

@discardableResult
func runBestEffort(
  _ executable: String,
  _ arguments: [String],
  environment: [String: String] = [:],
  workingDirectory: URL = repoRoot
) -> Int32 {
  logger.debug("runBestEffort executable=\(executable, privacy: .public)")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + arguments
  process.currentDirectoryURL = workingDirectory
  process.environment = mergedEnvironment(environment)

  do {
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  } catch {
    logger.error(
      """
      runBestEffort failed executable=\(executable, privacy: .public) \
      details=\(error.localizedDescription, privacy: .public) recovery=return-not-found-status
      """
    )
    return commandNotFoundExitStatus
  }
}

func capture(
  _ executable: String,
  _ arguments: [String],
  environment: [String: String] = [:],
  workingDirectory: URL = repoRoot,
  echoOutput: Bool = true,
  processRegistry: ProcessRegistry? = nil
) throws -> CommandResult {
  logger.debug("capture executable=\(executable, privacy: .public)")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [executable] + arguments
  process.currentDirectoryURL = workingDirectory

  process.environment = mergedEnvironment(environment)

  let outputPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = outputPipe

  let collected = ConcurrentDataBuffer()
  let readQueue = DispatchQueue(label: "celltunnel.capture.\(executable)")

  processRegistry?.add(process)
  defer { processRegistry?.remove(process) }

  try process.run()
  processRegistry?.noteRunning(process)
  let readCompletion = DispatchSemaphore(value: 0)
  readQueue.async {
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    collected.append(data)
    readCompletion.signal()
  }
  process.waitUntilExit()
  readCompletion.wait()

  let output = String(data: collected.data(), encoding: .utf8) ?? ""
  if echoOutput, !output.isEmpty {
    FileHandle.standardOutput.write(Data(output.utf8))
  }

  return CommandResult(status: process.terminationStatus, output: output)
}

// MARK: - ProcessRegistry

final class ProcessRegistry: @unchecked Sendable {
  private let lock = NSLock()
  private var processes: [ObjectIdentifier: Process] = [:]
  private var cancelRequested = false

  func add(_ process: Process) {
    // Register before run(). Never terminate here: Foundation aborts if
    // terminate() is called before the process has started.
    lock.lock()
    processes[ObjectIdentifier(process)] = process
    lock.unlock()
  }

  func noteRunning(_ process: Process) {
    lock.lock()
    let shouldKill = cancelRequested
    lock.unlock()
    if shouldKill, process.isRunning {
      process.terminate()
    }
  }

  func remove(_ process: Process) {
    lock.lock()
    processes.removeValue(forKey: ObjectIdentifier(process))
    lock.unlock()
  }

  func requestCancel() {
    lock.lock()
    cancelRequested = true
    let active = Array(processes.values)
    lock.unlock()
    for process in active where process.isRunning {
      process.terminate()
    }
  }

  func terminateAll() {
    requestCancel()
  }
}

// MARK: - ConcurrentDataBuffer

private final class ConcurrentDataBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func append(_ data: Data) {
    guard !data.isEmpty else {
      return
    }
    lock.lock()
    storage.append(data)
    lock.unlock()
  }

  func data() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
