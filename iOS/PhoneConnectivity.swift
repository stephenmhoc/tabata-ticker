import Foundation
import WatchConnectivity

@MainActor
final class PhoneConnectivity: NSObject, WCSessionDelegate {
    var onCommand: ((WatchCommandPayload) -> Void)?
    var onReady: (() -> Void)?

    func activate() {
        guard WCSession.isSupported() else {
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // WatchConnectivity writes to disk, so sending stays off the main thread. The queue is serial,
    // which keeps publishes in order.
    private nonisolated static let sendQueue = DispatchQueue(label: "com.merimerimeri.tabataticker.connectivity")

    func send(_ state: TabataState, catalog: TabataPresetCatalog) {
        Self.sendQueue.async {
            Self.deliver(state, catalog: catalog)
        }
    }

    private nonisolated static func deliver(_ state: TabataState, catalog: TabataPresetCatalog) {
        guard WCSession.isSupported() else {
            return
        }

        let session = WCSession.default

        // Without a paired watch app there is nothing to mirror to, and every send would fail.
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            return
        }

        let payload = state.payloadDictionary(catalog: catalog)

        do {
            try session.updateApplicationContext(payload)
        } catch {
            // Message delivery failures are routine when the watch app is asleep, but a rejected
            // application context means the watch has stopped mirroring the workout entirely.
            TabataDiagnostics.report("Sending workout state to the watch failed", error: error)
        }

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        notifyReady()
    }

    // Covers the watch app being installed while the phone app is already running.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        notifyReady()
    }

    private nonisolated func notifyReady() {
        Task { @MainActor in
            onReady?()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receive(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        receive(userInfo)
    }

    private nonisolated func receive(_ dictionary: [String: Any]) {
        guard let command = WatchCommandPayload.fromPayloadDictionary(dictionary) else {
            return
        }

        Task { @MainActor in
            onCommand?(command)
        }
    }
}
