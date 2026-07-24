//
//  LogsMode.swift
//  CellTunnelDev
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-22.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

// MARK: - Constants

private let logsLogger = CellTunnelLog.logger(category: .build)
private let macLogLinePrefix = "mac: "
private let iPhoneLogLinePrefix = "iphone: "
private let interruptExitStatus: Int32 = 130
private let terminationExitStatus: Int32 = 143
private let logsUsage = """
  usage: logs [--contains <text>] [--predicate <NSPredicate>]
              [--device <udid>] [--interval <seconds>]

  Streams Mac agent/provider logs and follows the attached iPhone unified log in
  one process. Mac lines are prefixed with `mac:`; iPhone lines with `iphone:`.
  Runs until Ctrl-C.

    --contains    Only show lines whose message contains <text>.
    --predicate   Raw NSPredicate instead of the io.goodkind.celltunnel
                  subsystem default. --contains still ANDs onto it.
    --device      Collect iPhone logs from a specific device UDID.
    --interval    Seconds between iPhone --follow polls (default 3).
  """

/// Namesake type so SwiftLint `file_name` matches `LogsMode.swift`.
enum LogsMode {}

// MARK: - Options

private struct LogsOptions {
  var containsFilter: String?
  var rawPredicate: String?
  var deviceOverride: String?
  var followIntervalSeconds = followDefaultIntervalSeconds
}

// MARK: - Entry point

func runLogs(_ arguments: [String]) throws {
  var options = LogsOptions()
  var iterator = arguments.makeIterator()
  while let argument = iterator.next() {
    switch argument {
    case "--contains":
      options.containsFilter = try requireLogsValue(&iterator, for: argument)
    case "--predicate":
      options.rawPredicate = try requireLogsValue(&iterator, for: argument)
    case "--device":
      options.deviceOverride = try requireLogsValue(&iterator, for: argument)
    case "--interval":
      options.followIntervalSeconds = try requireLogsInterval(&iterator, for: argument)
    case "-h", "--help":
      FileHandle.standardOutput.write(Data((logsUsage + "\n").utf8))
      return
    default:
      throw ToolError.usage("unknown logs argument: \(argument)")
    }
  }
  try streamBothLogs(options)
}

// MARK: - Dual stream

private func streamBothLogs(_ options: LogsOptions) throws {
  let predicate = cellTunnelUnifiedLogPredicate(
    containsFilter: options.containsFilter,
    rawPredicate: options.rawPredicate
  )
  let deviceUDID = resolvedDeviceUDID(override: options.deviceOverride)
  let cancellation = CancellationFlag()
  let interruptReceived = CancellationFlag()
  let terminationReceived = CancellationFlag()
  let processRegistry = ProcessRegistry()

  logsLogger.notice("logs dual-stream starting")
  FileHandle.standardError.write(
    Data("logs: streaming mac + iphone (Ctrl-C to stop)\n".utf8))

  let macProcess = try startMacLogStream(predicate: predicate)
  let signalSources = installLogInterruptHandlers(
    interruptReceived: interruptReceived,
    terminationReceived: terminationReceived,
    cancellation: cancellation,
    macProcess: macProcess,
    processRegistry: processRegistry
  )
  let iPhoneDone = startIPhoneFollow(
    context: IPhoneFollowContext(
      deviceUDID: deviceUDID,
      predicate: predicate,
      intervalSeconds: options.followIntervalSeconds,
      cancellation: cancellation,
      processRegistry: processRegistry,
      macProcess: macProcess
    )
  )

  let iPhoneError = finishDualStream(
    macProcess: macProcess,
    cancellation: cancellation,
    processRegistry: processRegistry,
    iPhoneDone: iPhoneDone,
    signalSources: signalSources
  )
  if let error = iPhoneError {
    throw error
  }
  if terminationReceived.isCancelled {
    throw LogsInterrupted(exitStatus: terminationExitStatus)
  }
  if interruptReceived.isCancelled {
    throw LogsInterrupted(exitStatus: interruptExitStatus)
  }
  if macProcess.terminationStatus != 0 {
    throw ToolError.failure(
      "mac log stream ended with status \(macProcess.terminationStatus)")
  }
}

private func startMacLogStream(predicate: String) throws -> PrefixedProcess {
  logsLogger.debug("logs starting mac unified-log stream")
  let macArguments = macLogStreamArguments(predicate: predicate)
  return try startPrefixedProcess(
    executable: "log",
    arguments: macArguments,
    linePrefix: macLogLinePrefix
  )
}

private func installLogInterruptHandlers(
  interruptReceived: CancellationFlag,
  terminationReceived: CancellationFlag,
  cancellation: CancellationFlag,
  macProcess: PrefixedProcess,
  processRegistry: ProcessRegistry
) -> [DispatchSourceSignal] {
  signal(SIGINT, SIG_IGN)
  signal(SIGTERM, SIG_IGN)
  let stop: () -> Void = {
    cancellation.cancel()
    macProcess.terminate()
    processRegistry.requestCancel()
  }
  let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
  sigintSource.setEventHandler {
    interruptReceived.cancel()
    stop()
  }
  sigintSource.resume()
  let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
  sigtermSource.setEventHandler {
    terminationReceived.cancel()
    stop()
  }
  sigtermSource.resume()
  return [sigintSource, sigtermSource]
}

// MARK: - IPhoneFollowContext

private struct IPhoneFollowContext {
  var deviceUDID: String?
  var predicate: String
  var intervalSeconds: Double
  var cancellation: CancellationFlag
  var processRegistry: ProcessRegistry
  var macProcess: PrefixedProcess
}

private func startIPhoneFollow(
  context: IPhoneFollowContext
) -> (DispatchSemaphore, ErrorBox) {
  let iPhoneDone = DispatchSemaphore(value: 0)
  let iPhoneError = ErrorBox()
  DispatchQueue.global(qos: .utility).async {
    defer { iPhoneDone.signal() }
    do {
      try followIPhoneLogs(
        deviceUDID: context.deviceUDID,
        predicate: context.predicate,
        intervalSeconds: context.intervalSeconds,
        cancellation: context.cancellation,
        processRegistry: context.processRegistry
      )
    } catch {
      if context.cancellation.isCancelled {
        logsLogger.debug("iphone log follow cancelled recovery=finish-dual-stream")
        return
      }
      logsLogger.error(
        """
        iphone log follow failed details=\(String(describing: error), privacy: .public) \
        recovery=stop-dual-stream
        """
      )
      iPhoneError.value = error
      context.cancellation.cancel()
      context.macProcess.terminate()
    }
  }
  return (iPhoneDone, iPhoneError)
}

private func finishDualStream(
  macProcess: PrefixedProcess,
  cancellation: CancellationFlag,
  processRegistry: ProcessRegistry,
  iPhoneDone: (DispatchSemaphore, ErrorBox),
  signalSources: [DispatchSourceSignal]
) -> Error? {
  macProcess.waitUntilExitAndDrain()
  cancellation.cancel()
  processRegistry.requestCancel()
  iPhoneDone.0.wait()
  for source in signalSources {
    source.cancel()
  }
  return iPhoneDone.1.value
}

private func followIPhoneLogs(
  deviceUDID: String?,
  predicate: String,
  intervalSeconds: Double,
  cancellation: CancellationFlag,
  processRegistry: ProcessRegistry
) throws {
  var previousCollectElapsed: TimeInterval = 0
  do {
    let collectStarted = Date()
    try collectAndShowUnifiedLog(
      deviceUDID: deviceUDID,
      lastDuration: unifiedLogDefaultDuration,
      predicate: predicate,
      linePrefix: iPhoneLogLinePrefix,
      processRegistry: processRegistry
    )
    previousCollectElapsed = Date().timeIntervalSince(collectStarted)
  } catch {
    if cancellation.isCancelled {
      return
    }
    throw error
  }
  while !cancellation.isCancelled {
    iPhoneLogsFollowDelay(seconds: intervalSeconds, cancellation: cancellation)
    if cancellation.isCancelled {
      return
    }
    let followWindow = iPhoneFollowWindowDuration(
      intervalSeconds: intervalSeconds,
      previousCollectElapsed: previousCollectElapsed
    )
    let collectStarted = Date()
    do {
      try collectAndShowUnifiedLog(
        deviceUDID: deviceUDID,
        lastDuration: followWindow,
        predicate: predicate,
        linePrefix: iPhoneLogLinePrefix,
        processRegistry: processRegistry
      )
    } catch {
      if cancellation.isCancelled {
        return
      }
      throw error
    }
    previousCollectElapsed = Date().timeIntervalSince(collectStarted)
  }
}

// MARK: - Parsing helpers

private func requireLogsValue(
  _ iterator: inout IndexingIterator<[String]>,
  for option: String
) throws -> String {
  guard let value = iterator.next() else {
    throw ToolError.usage("missing value for \(option)")
  }
  return value
}

private func requireLogsInterval(
  _ iterator: inout IndexingIterator<[String]>,
  for option: String
) throws -> Double {
  let raw = try requireLogsValue(&iterator, for: option)
  guard let seconds = Double(raw), seconds > 0 else {
    throw ToolError.usage("\(option) must be a positive number of seconds")
  }
  return seconds
}

// MARK: - LogsInterrupted

struct LogsInterrupted: Error {
  let exitStatus: Int32
}

// MARK: - ErrorBox

private final class ErrorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Error?

  var value: Error? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      stored = newValue
      lock.unlock()
    }
  }
}
