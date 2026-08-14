//
//  AgentSystemExtension.swift
//  CellTunnelAgent
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-08-13.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelLog
import Foundation

#if CELL_TUNNEL_SYSTEM_EXTENSION
  import SystemExtensions
#endif

private let logger = CellTunnelLog.logger(category: .daemon)

// MARK: - Activation

/// Activates the tunnel that the downloadable build ships as a system extension.
///
/// A packet tunnel packaged as a system extension does not exist for
/// NetworkExtension until macOS has activated it, so a profile pointing at it fails
/// to start until this has run once. macOS asks the person to allow it the first
/// time and remembers the answer, so later launches resolve immediately. Only an app
/// the person launched may submit the request, which is why this lives in the agent
/// rather than in the extension.
///
/// The build that ships the tunnel as an app extension has nothing to activate,
/// because macOS registers that provider from the app bundle itself.
enum AgentSystemExtension {
  /// Submits the activation request and returns once macOS has an answer.
  ///
  /// Returning normally means the extension is active, including the case where it
  /// already was. Throwing means the person declined, macOS refused the bundle, or
  /// the caller was cancelled, and the caller must not pretend a tunnel can start.
  static func activateIfNeeded(identifier: String) async throws {
    #if CELL_TUNNEL_SYSTEM_EXTENSION
      let delegate = ActivationDelegate()
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          delegate.submitRequest(identifier: identifier, continuation: continuation)
        }
      } onCancel: {
        delegate.abandon()
      }
    #else
      logger.debug(
        "agent has no system extension to activate id=\(identifier, privacy: .public)"
      )
    #endif
  }
}

#if CELL_TUNNEL_SYSTEM_EXTENSION

  // MARK: - Request delegate

  /// Bridges the request's callbacks to the caller.
  ///
  /// Each outcome resumes the caller exactly once, because macOS reports approval and
  /// completion separately and a person can leave the prompt unanswered for as long as
  /// they like. A lock guards that single resume, since the cancellation handler runs
  /// on whichever thread cancelled the caller while the request answers on the main
  /// queue.
  private final class ActivationDelegate: NSObject, OSSystemExtensionRequestDelegate,
    @unchecked Sendable
  {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    /// A request holds its delegate weakly, so once the submitting call returns
    /// nothing else refers to this object and macOS would report the outcome to a
    /// deallocated delegate, leaving the caller suspended forever. Holding itself
    /// until a callback resumes the caller is what keeps the outcome deliverable.
    private var pendingSelf: ActivationDelegate?

    /// Retains this delegate, submits the request, and leaves the caller suspended
    /// until macOS answers.
    func submitRequest(
      identifier: String,
      continuation: CheckedContinuation<Void, Error>
    ) {
      lock.lock()
      self.continuation = continuation
      pendingSelf = self
      lock.unlock()

      let request = OSSystemExtensionRequest.activationRequest(
        forExtensionWithIdentifier: identifier,
        queue: .main
      )
      request.delegate = self
      OSSystemExtensionManager.shared.submitRequest(request)
      logger.notice(
        "agent submitted system extension activation id=\(identifier, privacy: .public)"
      )
    }

    /// Frees a cancelled caller. macOS offers no way to withdraw a submitted request,
    /// so the request runs to its own end and its outcome is discarded; a later call
    /// submits a fresh one, and activation is idempotent.
    func abandon() {
      logger.notice("agent abandoned system extension activation reason=cancelled")
      resume(with: .failure(CancellationError()))
    }

    // MARK: Delegate callbacks

    /// An upgrade replaces the running copy, which is what a new build of the app
    /// installing a new build of the extension always means here.
    func request(
      _: OSSystemExtensionRequest,
      actionForReplacingExtension existing: OSSystemExtensionProperties,
      withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
      logger.notice(
        """
        agent replacing system extension \
        from=\(existing.bundleVersion, privacy: .public) \
        to=\(replacement.bundleVersion, privacy: .public)
        """
      )
      return .replace
    }

    /// macOS is showing the approval prompt. The request stays open until the person
    /// answers, so this reports progress and waits rather than resuming.
    func requestNeedsUserApproval(_: OSSystemExtensionRequest) {
      logger.notice("agent system extension awaiting approval")
    }

    func request(
      _: OSSystemExtensionRequest,
      didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
      logger.notice(
        "agent system extension activated result=\(result.rawValue, privacy: .public)"
      )
      resume(with: .success(()))
    }

    func request(_: OSSystemExtensionRequest, didFailWithError error: Error) {
      logger.error(
        """
        agent system extension activation failed \
        details=\(String(describing: error), privacy: .public) \
        recovery=propagate-to-caller
        """
      )
      resume(with: .failure(error))
    }

    // MARK: Single resume

    private func resume(with outcome: Result<Void, Error>) {
      lock.lock()
      let pending = continuation
      continuation = nil
      pendingSelf = nil
      lock.unlock()

      guard let pending else {
        return
      }
      pending.resume(with: outcome)
    }
  }

#endif
