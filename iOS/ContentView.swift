import SwiftUI

private enum ContentRoute: Hashable {
    case settings
    case createPreset
    case editPreset(String)

    var presetID: String? {
        switch self {
        case .settings, .createPreset:
            nil
        case .editPreset(let presetID):
            presetID
        }
    }

    var title: String {
        switch self {
        case .settings:
            "Settings"
        case .createPreset:
            "New Preset"
        case .editPreset:
            "Edit Preset"
        }
    }

    var saveTitle: String {
        switch self {
        case .settings:
            ""
        case .createPreset:
            "Create Preset"
        case .editPreset:
            "Save Preset"
        }
    }
}

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let viewModel: WorkoutViewModel
    @State private var path: [ContentRoute] = []

    // Required rather than defaulted: a default would quietly build a second view model, and with it
    // a second engine and a second WatchConnectivity delegate.
    init(viewModel: WorkoutViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                phaseBackdrop

                // Follows the space the window really has, so iPad landscape, Split View and Stage
                // Manager each get a layout that fills them.
                GeometryReader { proxy in
                    let isWide = proxy.size.width > proxy.size.height * 1.15

                    VStack(spacing: metrics.verticalSpacing) {
                        if showsHeader {
                            header
                        }

                        if isWide {
                            HStack(spacing: metrics.verticalSpacing) {
                                clock(in: CGSize(width: proxy.size.width * 0.58, height: proxy.size.height))

                                VStack(spacing: metrics.readoutSpacing) {
                                    title
                                    roundDetails
                                    Spacer(minLength: 0)
                                    controls
                                }
                            }
                            .frame(maxHeight: .infinity)
                        } else {
                            VStack(spacing: metrics.readoutSpacing) {
                                title
                                clock(in: proxy.size)
                                roundDetails
                            }

                            Spacer(minLength: 18)

                            controls
                        }
                    }
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.vertical, metrics.verticalPadding)
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: viewModel.state.phase)
            }
            .sensoryFeedback(trigger: phaseKey) { _, _ in
                transitionFeedback
            }
            .onChange(of: presentation.spokenPhase) { _, spokenPhase in
                if let spokenPhase {
                    AccessibilityNotification.Announcement(spokenPhase).post()
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: ContentRoute.self) { route in
                screen(for: route)
            }
        }
        .tint(.white.opacity(0.86))
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.activate()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.refreshLiveActivity()
            }
        }
    }

    // The phase's colour drains away as its time runs out, so how long is left reads from across
    // the room without seeing a digit. Reduce Motion keeps the screen full.
    private var phaseBackdrop: some View {
        let state = viewModel.state
        let gradient = LinearGradient(colors: backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)

        return ZStack {
            gradient
                .overlay(.black.opacity(0.42))

            // Drawn from the display's own clock, because the workout's tick is far too coarse and
            // uneven to animate from.
            TimelineView(.animation(paused: !state.isRunning || reduceMotion)) { context in
                let fraction = reduceMotion ? 1 : state.phaseFraction(at: context.date)

                gradient
                    .mask(alignment: .bottom) {
                        GeometryReader { proxy in
                            Rectangle()
                                .frame(height: proxy.size.height * fraction)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
            }
        }
        .animation(.smooth(duration: 0.35), value: presentation.title)
        .ignoresSafeArea()
    }

    private var phaseKey: String {
        "\(viewModel.state.phase.rawValue)-\(viewModel.state.round)"
    }

    private var transitionFeedback: SensoryFeedback? {
        guard viewModel.state.settings.hapticsEnabled else {
            return nil
        }

        switch viewModel.state.phase {
        case .work:
            return .impact(weight: .heavy)
        case .rest:
            return .impact(weight: .light)
        case .complete:
            return .success
        case .idle, .countdown:
            return nil
        }
    }

    @ViewBuilder
    private func screen(for route: ContentRoute) -> some View {
        switch route {
        case .settings:
            settingsScreen
        case .createPreset, .editPreset:
            presetEditorScreen(for: route)
        }
    }

    private var settingsScreen: some View {
        ZStack {
            LinearGradient(colors: backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            SettingsView(
                soundsEnabled: Binding(
                    get: { viewModel.state.settings.soundsEnabled },
                    set: { viewModel.setSoundsEnabled($0) }
                ),
                hapticsEnabled: Binding(
                    get: { viewModel.state.settings.hapticsEnabled },
                    set: { viewModel.setHapticsEnabled($0) }
                ),
                startCountdownEnabled: Binding(
                    get: { viewModel.state.settings.startCountdownEnabled },
                    set: { viewModel.setStartCountdownEnabled($0) }
                ),
                presets: viewModel.presets,
                canManageCustomPresets: viewModel.canManageCustomPresets,
                onEditPreset: { preset in
                    path.append(.editPreset(preset.id))
                },
                onDeletePreset: { preset in
                    viewModel.deletePreset(id: preset.id)
                }
            )
            .frame(maxWidth: metrics.contentMaxWidth)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func presetEditorScreen(for route: ContentRoute) -> some View {
        let preset = route.presetID.flatMap { id in viewModel.presets.first { $0.id == id } }
        let initialConfig = preset?.config ?? .classic

        return ZStack {
            LinearGradient(colors: backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            PresetEditorView(
                title: route.title,
                saveTitle: route.saveTitle,
                initialConfig: initialConfig,
                initialName: preset?.customName,
                existingPresetID: preset?.id,
                canCreatePreset: viewModel.canCreatePreset,
                onSave: { config, name in
                    let didSave: Bool
                    switch route {
                    case .settings:
                        didSave = false
                    case .createPreset:
                        didSave = viewModel.createPreset(config: config, name: name)
                    case .editPreset(let presetID):
                        didSave = viewModel.updatePreset(id: presetID, config: config, name: name)
                    }

                    if didSave {
                        path.removeLast()
                    }
                    return didSave
                }
            )
            .frame(maxWidth: metrics.contentMaxWidth)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // A running workout shows nothing that can't be used mid-exercise.
    private var showsHeader: Bool {
        !viewModel.state.isRunning
    }

    private var header: some View {
        HStack {
            if viewModel.state.phase == .idle {
                presetMenu
            }

            Spacer()

            Button {
                withAnimation(.smooth(duration: 0.28)) {
                    path.append(.settings)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(metrics.settingsButtonFont)
                    .frame(width: metrics.settingsButtonSize, height: metrics.settingsButtonSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.86))
            .accessibilityLabel("Settings")
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(viewModel.presets) { preset in
                Button {
                    viewModel.selectPreset(preset)
                } label: {
                    Label(preset.name, systemImage: preset.id == viewModel.selectedPreset.id ? "checkmark" : "timer")
                }
            }

            if viewModel.canCreatePreset {
                Divider()

                Button {
                    path.append(.createPreset)
                } label: {
                    Label("New Preset", systemImage: "plus")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.headline.weight(.bold))

                Text(viewModel.selectedPreset.name)
                    .font(.headline.weight(.bold))
                    .monospacedDigit()

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
            }
            .frame(minWidth: 116, minHeight: metrics.settingsButtonSize)
            .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .foregroundStyle(glassControlForeground)
        .accessibilityLabel("Preset")
        .accessibilityValue(viewModel.selectedPreset.name)
    }

    private var title: some View {
        Text(presentation.title)
            .font(.system(size: metrics.titleSize, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.6)
            .contentTransition(.opacity)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func clock(in size: CGSize) -> some View {
        // Sized for two digits, with the height fixed, so nothing moves when the count reaches 9.
        let fontSize = min(size.width * 0.76, size.height * 0.46)

        Group {
            if viewModel.state.phase == .complete {
                Image(systemName: "checkmark")
                    .font(.system(size: fontSize * 0.7, weight: .black, design: .rounded))
                    .symbolEffect(.bounce, value: viewModel.state.phase)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                Text(timeText)
                    .font(.system(size: fontSize, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: timeText)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: fontSize * 0.86)
        .keyframeAnimator(initialValue: 1.0, trigger: finalSecondsPulse) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(pulsePeak, duration: 0.12)
                SpringKeyframe(1.0, duration: 0.3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue("\(remainingSeconds) seconds, \(presentation.phoneRoundText)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var roundDetails: some View {
        VStack(spacing: 12) {
            Text(presentation.phoneRoundText)
                .font(metrics.roundFont)
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()

            RoundPips(
                total: viewModel.state.config.rounds,
                completed: viewModel.state.completedRounds,
                isOnRound: viewModel.state.phase == .work
            )
            .frame(maxWidth: metrics.controlsMaxWidth)

            if let nextText = presentation.nextText {
                Text(nextText)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            primaryActionButton
                .keyboardShortcut(.space, modifiers: [])

            if presentation.showsReset {
                Button {
                    viewModel.reset()
                } label: {
                    Text(presentation.resetButtonTitle)
                        .frame(maxWidth: .infinity, minHeight: metrics.resetButtonHeight)
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(.black)
            }
        }
        .font(metrics.primaryButtonFont)
        .controlSize(.large)
        .frame(maxWidth: metrics.controlsMaxWidth)
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if isPaused {
            Button {
                primaryAction()
            } label: {
                Text(presentation.primaryButtonTitle)
                    .frame(maxWidth: .infinity, minHeight: metrics.primaryButtonHeight)
            }
            .buttonStyle(.glassProminent)
            .tint(resumeButtonTint)
            .foregroundStyle(.white)
        } else if isPrimaryButtonProminent {
            Button {
                primaryAction()
            } label: {
                Text(presentation.primaryButtonTitle)
                    .frame(maxWidth: .infinity, minHeight: metrics.primaryButtonHeight)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.black)
        } else {
            Button {
                primaryAction()
            } label: {
                Text(presentation.primaryButtonTitle)
                    .frame(maxWidth: .infinity, minHeight: metrics.primaryButtonHeight)
            }
            .buttonStyle(.glass)
            .foregroundStyle(glassControlForeground)
        }
    }

    private func primaryAction() {
        if presentation.primaryAction == .reset {
            viewModel.reset()
        } else {
            viewModel.toggleRunning()
        }
    }

    private var isPrimaryButtonProminent: Bool {
        presentation.isPrimaryButtonProminent
    }

    private var isPaused: Bool {
        viewModel.state.isWorkoutPhase && !viewModel.state.isRunning
    }

    private var metrics: TimerMetrics {
        TimerMetrics(horizontalSizeClass: horizontalSizeClass)
    }

    private var presentation: TabataPresentation {
        TabataPresentation(state: viewModel.state)
    }

    private var remainingSeconds: Int {
        max(0, Int(ceil(viewModel.state.remaining(at: viewModel.now))))
    }

    // The home screen says how long the whole workout takes; after that it's the current phase.
    private var timeText: String {
        if viewModel.state.phase == .idle {
            return TabataClock.text(seconds: Int(viewModel.state.config.totalDuration.rounded()))
        }

        return TabataClock.compactText(seconds: remainingSeconds)
    }

    private var pulsePeak: Double {
        finalSecondsPulse == nil || reduceMotion ? 1.0 : 1.12
    }

    // Each of the last three seconds of a phase gives the digits a beat.
    private var finalSecondsPulse: Int? {
        guard viewModel.state.isRunning, (1...3).contains(remainingSeconds) else {
            return nil
        }

        return remainingSeconds
    }

    private var backgroundColors: [Color] {
        [Color(presentation.background.start), Color(presentation.background.end)]
    }

    private var resumeButtonTint: Color {
        Color(red: 0.00, green: 0.48, blue: 0.95)
    }
}

private struct RoundPips: View {
    let total: Int
    let completed: Int
    let isOnRound: Bool

    var body: some View {
        HStack(spacing: total > 16 ? 3 : 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(opacity(for: index)))
                    .frame(height: 8)
            }
        }
        .animation(.smooth(duration: 0.3), value: completed)
    }

    private func opacity(for index: Int) -> Double {
        if index < completed {
            return 1
        }

        return index == completed && isOnRound ? 0.6 : 0.22
    }
}
