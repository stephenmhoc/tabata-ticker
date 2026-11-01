import SwiftUI

struct SettingsView: View {
    @Binding var soundsEnabled: Bool
    @Binding var hapticsEnabled: Bool
    @Binding var startCountdownEnabled: Bool
    let presets: [TabataPreset]
    let canManageCustomPresets: Bool
    let onEditPreset: (TabataPreset) -> Void
    let onDeletePreset: (TabataPreset) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings")
                    .font(.system(.largeTitle, design: .rounded).weight(.black))
                    .foregroundStyle(.white)

                Toggle(isOn: $soundsEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enable Sounds")
                            .font(.headline)

                        Text(soundsEnabled ? "On" : "Off")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .tint(.green)
                .foregroundStyle(.white)

                Toggle(isOn: $hapticsEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Haptic Feedback")
                            .font(.headline)

                        Text(hapticsEnabled ? "On" : "Off")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .tint(.green)
                .foregroundStyle(.white)

                Toggle(isOn: $startCountdownEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Start Countdown before Workout")
                            .font(.headline)

                        Text(startCountdownEnabled ? "5 seconds" : "Off")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .tint(.green)
                .foregroundStyle(.white)

                PresetSettingsSection(
                    presets: presets,
                    canManageCustomPresets: canManageCustomPresets,
                    onEditPreset: onEditPreset,
                    onDeletePreset: onDeletePreset
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PresetSettingsSection: View {
    let presets: [TabataPreset]
    let canManageCustomPresets: Bool
    let onEditPreset: (TabataPreset) -> Void
    let onDeletePreset: (TabataPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "timer")
                    .font(.headline.weight(.black))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.14), in: Circle())

                Text("Presets")
                    .font(.title2.weight(.black))
            }
            .foregroundStyle(.white)

            VStack(spacing: 0) {
                ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                    PresetSettingsRow(
                        preset: preset,
                        canManageCustomPresets: canManageCustomPresets,
                        onEdit: {
                            onEditPreset(preset)
                        },
                        onDelete: {
                            onDeletePreset(preset)
                        }
                    )
                    .padding(.vertical, 10)

                    if index < presets.count - 1 {
                        Divider()
                            .overlay(.white.opacity(0.18))
                    }
                }
            }
        }
        .padding(18)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct PresetSettingsRow: View {
    let preset: TabataPreset
    let canManageCustomPresets: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name)
                    .font(.title3.weight(.black))
                    .monospacedDigit()

                Text(statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer(minLength: 12)

            if preset.isDefault {
                Image(systemName: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Default preset")
            } else if canManageCustomPresets {
                HStack(spacing: 8) {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.headline.weight(.bold))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.glass)
                    .foregroundStyle(glassControlForeground)
                    .accessibilityLabel("Edit \(preset.name)")

                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.headline.weight(.bold))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.glass)
                    .foregroundStyle(glassControlForeground)
                    .accessibilityLabel("Delete \(preset.name)")
                    .confirmationDialog("Delete preset?", isPresented: $isConfirmingDelete) {
                        Button("Delete \(preset.name)", role: .destructive, action: onDelete)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("\(preset.name) will be removed permanently.")
                    }
                }
            } else {
                Image(systemName: "lock.fill")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Preset changes unavailable during workout")
            }
        }
        .foregroundStyle(.white)
    }

    // A named preset shows its timings underneath, since the name alone no longer says what it runs.
    private var statusText: String {
        let kind = preset.isDefault ? "Default" : "Custom"
        return preset.hasCustomName ? "\(preset.timingText) · \(kind)" : kind
    }
}
