import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivity: NSObject, WCSessionDelegate {
    var onState: ((TabataState) -> Void)?
    var onCatalog: ((TabataPresetCatalog) -> Void)?
    private var lastRevision: TimeInterval = 0

    func activate() {
        guard WCSession.isSupported() else {
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()
        deliver(session.receivedApplicationContext)
    }

    func send(_ command: WatchCommandPayload) {
        guard WCSession.isSupported() else {
            return
        }

        Self.deliver(command.payloadDictionary(), over: WCSession.default)
    }

    // Nonisolated because WatchConnectivity calls the error handler on its own queue, and a closure
    // written on the main actor would trap there.
    private nonisolated static func deliver(_ payload: [String: Any], over session: WCSession) {
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    // Decoded before hopping to the main actor, because the payload dictionary itself is not Sendable.
    private nonisolated func receive(_ dictionary: [String: Any]) {
        guard let state = TabataState.fromPayloadDictionary(dictionary) else {
            return
        }

        let catalog = TabataState.catalogFromPayloadDictionary(dictionary)
        let revision = TabataState.revisionFromPayloadDictionary(dictionary)

        Task { @MainActor in
            apply(state: state, catalog: catalog, revision: revision)
        }
    }

    private func deliver(_ dictionary: [String: Any]) {
        guard let state = TabataState.fromPayloadDictionary(dictionary) else {
            return
        }

        apply(
            state: state,
            catalog: TabataState.catalogFromPayloadDictionary(dictionary),
            revision: TabataState.revisionFromPayloadDictionary(dictionary)
        )
    }

    // A phone that predates preset syncing sends the state on its own, so the catalog is optional.
    private func apply(state: TabataState, catalog: TabataPresetCatalog?, revision: TimeInterval?) {
        if let revision {
            guard revision >= lastRevision else {
                return
            }

            lastRevision = revision
        }

        onState?(state)

        if let catalog {
            onCatalog?(catalog)
        }
    }
}
