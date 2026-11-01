import SwiftUI

struct PresetEditorView: View {
    // The same ranges the stored presets are clamped to, so the editor cannot offer a value that
    // the catalog would quietly rewrite.
    private static let workRange = TabataConfig.workSecondsRange
    private static let restRange = TabataConfig.restSecondsRange
    private static let roundsRange = TabataConfig.roundsRange

    let title: String
    let saveTitle: String
    let existingPresetID: String?
    let canCreatePreset: Bool
    let onSave: (TabataConfig, String?) -> Bool

    @State private var name: String
    @State private var workSeconds: Int
    @State private var restSeconds: Int
    @State private var rounds: Int
    @State private var showsSaveError = false
    @FocusState private var isNamingPreset: Bool

    init(
        title: String,
        saveTitle: String,
        initialConfig: TabataConfig,
        initialName: String?,
        existingPresetID: String?,
        canCreatePreset: Bool,
        onSave: @escaping (TabataConfig, String?) -> Bool
    ) {
        self.title = title
        self.saveTitle = saveTitle
        self.existingPresetID = existingPresetID
        self.canCreatePreset = canCreatePreset
        self.onSave = onSave
        _name = State(initialValue: initialName ?? "")
        _workSeconds = State(initialValue: Self.clamped(initialConfig.workSeconds, to: Self.workRange))
        _restSeconds = State(initialValue: Self.clamped(initialConfig.restSeconds, to: Self.restRange))
        _rounds = State(initialValue: Self.clamped(initialConfig.rounds, to: Self.roundsRange))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(.largeTitle, design: .rounded).weight(.black))

                    // Empty means the preset keeps showing its timings, so the field is optional rather
                    // than something to fill in before saving.
                    TextField("Name (optional)", text: $name)
                        .font(.system(.title, design: .rounded).weight(.black))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isNamingPreset)
                        .onSubmit {
                            isNamingPreset = false
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Preset name")

                    Text("\(config.presetName) · \(TabataClock.text(seconds: Int(config.totalDuration.rounded()))) total")
                        .font(.headline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)

                VStack(spacing: 16) {
                    PresetValueControl(
                        title: "Work Time",
                        value: "\(workSeconds) sec",
                        decrementDisabled: workSeconds <= Self.workRange.lowerBound,
                        incrementDisabled: workSeconds >= Self.workRange.upperBound,
                        onDecrement: {
                            adjustWork(by: -5)
                        },
                        onIncrement: {
                            adjustWork(by: 5)
                        }
                    )

                    PresetValueControl(
                        title: "Rest Time",
                        value: "\(restSeconds) sec",
                        decrementDisabled: restSeconds <= Self.restRange.lowerBound,
                        incrementDisabled: restSeconds >= Self.restRange.upperBound,
                        onDecrement: {
                            adjustRest(by: -5)
                        },
                        onIncrement: {
                            adjustRest(by: 5)
                        }
                    )

                    PresetValueControl(
                        title: "Rounds",
                        value: "\(rounds) \(rounds == 1 ? "round" : "rounds")",
                        decrementDisabled: rounds <= Self.roundsRange.lowerBound,
                        incrementDisabled: rounds >= Self.roundsRange.upperBound,
                        onDecrement: {
                            adjustRounds(by: -1)
                        },
                        onIncrement: {
                            adjustRounds(by: 1)
                        }
                    )
                }

                if let validationText {
                    Text(validationText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.76))
                }

                Button {
                    showsSaveError = !onSave(config, TabataPreset.sanitizedName(name))
                } label: {
                    Text(saveTitle)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(.black)
                .font(.headline.weight(.bold))
                .disabled(!canSave)
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var config: TabataConfig {
        TabataConfig.preset(workSeconds: workSeconds, restSeconds: restSeconds, rounds: rounds)
    }

    private var canSave: Bool {
        existingPresetID != nil || canCreatePreset
    }

    private var validationText: String? {
        if existingPresetID == nil, !canCreatePreset {
            return "Preset limit reached"
        }
        if showsSaveError {
            return "Unable to save preset"
        }
        return nil
    }

    private func adjustWork(by amount: Int) {
        workSeconds = Self.clamped(workSeconds + amount, to: Self.workRange)
        showsSaveError = false
    }

    private func adjustRest(by amount: Int) {
        restSeconds = Self.clamped(restSeconds + amount, to: Self.restRange)
        showsSaveError = false
    }

    private func adjustRounds(by amount: Int) {
        rounds = Self.clamped(rounds + amount, to: Self.roundsRange)
        showsSaveError = false
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct PresetValueControl: View {
    let title: String
    let value: String
    let decrementDisabled: Bool
    let incrementDisabled: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline.weight(.semibold))

                Text(value)
                    .font(.system(.title, design: .rounded).weight(.black))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)

            Spacer(minLength: 10)

            HStack(spacing: 8) {
                Button(action: onDecrement) {
                    Image(systemName: "minus")
                        .font(.headline.weight(.black))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.glass)
                .foregroundStyle(glassControlForeground)
                .disabled(decrementDisabled)
                .buttonRepeatBehavior(.enabled)
                .accessibilityLabel("Decrease \(title)")

                Button(action: onIncrement) {
                    Image(systemName: "plus")
                        .font(.headline.weight(.black))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.glass)
                .foregroundStyle(glassControlForeground)
                .disabled(incrementDisabled)
                .buttonRepeatBehavior(.enabled)
                .accessibilityLabel("Increase \(title)")
            }
        }
    }
}
