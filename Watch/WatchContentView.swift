import SwiftUI

struct WatchContentView: View {
    @State private var viewModel = WatchWorkoutViewModel()
    @State private var isChoosingPreset = false
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(colors: backgroundColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(.black.opacity(isLuminanceReduced ? 0.7 : 0))
                .animation(.smooth(duration: 0.3), value: presentation.title)
                .ignoresSafeArea()

            VStack(spacing: 4) {
                Text(presentation.title)
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)

                Group {
                    if viewModel.state.phase == .complete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 48, weight: .black, design: .rounded))
                            .symbolEffect(.bounce, value: viewModel.state.phase)
                    } else {
                        Text(timeText)
                            .font(.system(size: 76, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.snappy(duration: 0.2), value: timeText)
                    }
                }
                .foregroundStyle(.white)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presentation.title)
                .accessibilityValue("\(remainingSeconds) seconds, \(presentation.watchRoundText)")
                .accessibilityAddTraits(.updatesFrequently)

                if !isLuminanceReduced, viewModel.state.phase != .idle, viewModel.state.phase != .complete {
                    phaseBar
                }

                // Takes the place of the round count rather than adding a row, which does not fit on
                // the smallest watches. The preset name says the same thing and more.
                if viewModel.canSelectPreset {
                    Button {
                        isChoosingPreset = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "timer")

                            Text(viewModel.selectedPreset.name)
                                .monospacedDigit()
                        }
                        .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .foregroundStyle(.white)
                    .accessibilityLabel("Preset")
                    .accessibilityValue(viewModel.selectedPreset.name)
                } else {
                    Text(presentation.watchRoundText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    // The double-tap gesture, for when both hands are busy.
                    primaryActionButton
                        .handGestureShortcut(.primaryAction)

                    if presentation.showsReset {
                        Button {
                            viewModel.reset()
                        } label: {
                            Text(presentation.resetButtonTitle)
                                .frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.glass)
                        .foregroundStyle(.white)
                    }
                }
                .font(.caption.weight(.bold))
                .controlSize(.small)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
        .onAppear {
            viewModel.activate()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.sceneBecameActive()
            }
        }
        .onChange(of: presentation.spokenPhase) { _, spokenPhase in
            if let spokenPhase {
                AccessibilityNotification.Announcement(spokenPhase).post()
            }
        }
        .sheet(isPresented: $isChoosingPreset) {
            presetPicker
        }
    }

    private var phaseBar: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.white.opacity(0.25))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.white)
                        .frame(width: proxy.size.width * viewModel.state.phaseFraction(at: viewModel.now))
                        .animation(.linear(duration: 0.5), value: viewModel.now)
                }
        }
        .frame(height: 5)
        .padding(.horizontal, 12)
        .accessibilityHidden(true)
    }

    private var presetPicker: some View {
        NavigationStack {
            presetList
                .navigationTitle("Preset")
        }
    }

    private var presetList: some View {
        List {
            ForEach(viewModel.presets) { preset in
                Button {
                    viewModel.selectPreset(preset)
                    isChoosingPreset = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.name)
                                .font(.body.weight(.semibold))
                                .monospacedDigit()

                            if preset.hasCustomName {
                                Text(preset.timingText)
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 8)

                        if preset.id == viewModel.selectedPreset.id {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if isPrimaryButtonProminent {
            Button {
                primaryAction()
            } label: {
                Text(presentation.primaryButtonTitle)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.white)
        } else {
            Button {
                primaryAction()
            } label: {
                Text(presentation.primaryButtonTitle)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glass)
            .foregroundStyle(.white)
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

    private var presentation: TabataPresentation {
        TabataPresentation(state: viewModel.state)
    }

    private var remainingSeconds: Int {
        max(0, Int(ceil(viewModel.state.remaining(at: viewModel.now))))
    }

    private var timeText: String {
        if viewModel.state.phase == .idle {
            return TabataClock.text(seconds: Int(viewModel.state.config.totalDuration.rounded()))
        }

        return TabataClock.compactText(seconds: remainingSeconds)
    }

    private var backgroundColors: [Color] {
        [Color(presentation.background.start), Color(presentation.background.end)]
    }

}

private extension Color {
    init(_ tabataColor: TabataColor) {
        self.init(red: tabataColor.red, green: tabataColor.green, blue: tabataColor.blue)
    }
}
