//
//  ConfigDocumentPicker.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-23.
//  Copyright © 2026, all rights reserved.
//

#if targetEnvironment(macCatalyst)
  import SwiftUI
  import UniformTypeIdentifiers
  import UIKit

  // MARK: - ConfigDocumentPicker

  struct ConfigDocumentPicker: UIViewControllerRepresentable {
    struct Request {
      let id: UUID
      let allowedContentTypes: [UTType]
    }

    let request: Request?
    let completion: (UUID, Result<[URL], Error>) -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
      let hostController = UIViewController()
      context.coordinator.attach(hostController: hostController)
      return hostController
    }

    func updateUIViewController(
      _: UIViewController,
      context: Context
    ) {
      context.coordinator.update(request: request, completion: completion)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate,
      UIAdaptivePresentationControllerDelegate
    {
      private var activePicker: UIDocumentPickerViewController?
      private var activeRequestID: UUID?
      private var completion: ((UUID, Result<[URL], Error>) -> Void)?
      private var hostController: UIViewController?
      private var pendingResult: Result<[URL], Error>?

      func attach(hostController: UIViewController) {
        self.hostController = hostController
      }

      func update(
        request: Request?,
        completion: @escaping (UUID, Result<[URL], Error>) -> Void
      ) {
        self.completion = completion
        guard let request, activePicker == nil else {
          return
        }
        presentPicker(for: request)
      }

      func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
      ) {
        dismiss(controller, with: .success(urls))
      }

      func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        dismiss(controller, with: .success([]))
      }

      func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard
          pendingResult == nil,
          let picker = presentationController.presentedViewController
            as? UIDocumentPickerViewController,
          isActivePicker(picker)
        else {
          return
        }
        pendingResult = .success([])
        finishPendingResult(for: picker)
      }

      private func dismiss(
        _ picker: UIDocumentPickerViewController,
        with result: Result<[URL], Error>
      ) {
        guard
          isActivePicker(picker),
          pendingResult == nil,
          let hostController
        else {
          return
        }
        pendingResult = result
        hostController.dismiss(animated: true) { [weak self, weak picker] in
          guard let picker else {
            return
          }
          self?.finishPendingResult(for: picker)
        }
      }

      private func presentPicker(for request: Request) {
        guard let hostController, hostController.presentedViewController == nil else {
          return
        }
        let picker = UIDocumentPickerViewController(
          forOpeningContentTypes: request.allowedContentTypes,
          asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.delegate = self
        activePicker = picker
        activeRequestID = request.id
        pendingResult = nil
        hostController.present(picker, animated: true)
        picker.presentationController?.delegate = self
      }

      private func isActivePicker(_ controller: UIDocumentPickerViewController) -> Bool {
        activePicker === controller
      }

      private func finishPendingResult(for picker: UIDocumentPickerViewController) {
        guard
          isActivePicker(picker),
          let activeRequestID,
          let completion,
          let pendingResult
        else {
          return
        }
        activePicker?.presentationController?.delegate = nil
        activePicker = nil
        self.activeRequestID = nil
        self.completion = nil
        self.pendingResult = nil
        completion(activeRequestID, pendingResult)
      }
    }
  }

#endif
