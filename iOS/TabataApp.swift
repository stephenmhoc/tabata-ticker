import Sentry
import SwiftUI

@main
struct TabataApp: App {
    private let viewModel: WorkoutViewModel

    init() {
        Self.startCrashReporting()
        viewModel = WorkoutViewModel.shared()
        viewModel.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }

    // Started before anything else so a failure during setup is still reported.
    private static func startCrashReporting() {
        SentrySDK.start { options in
            options.dsn = "https://94c61c649894387423afa32b1e249c68@o4510771621789696.ingest.us.sentry.io/4511798342778880"
            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "production"
            #endif
            options.tracesSampleRate = 0.2
            options.attachScreenshot = true
            options.attachViewHierarchy = true
        }

        TabataDiagnostics.setReporter { context, error in
            if let error {
                SentrySDK.capture(error: error) { scope in
                    scope.setContext(value: ["detail": context], key: "tabata")
                    scope.setTag(value: context, key: "operation")
                }
                return
            }

            SentrySDK.capture(message: context)
        }
    }
}
