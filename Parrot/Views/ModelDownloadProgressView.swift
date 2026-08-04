import SwiftUI

struct ModelDownloadProgressView: View {
    let progress: Double
    var modelName: String? = nil

    private var boundedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var title: String {
        modelName.map { "Downloading \($0)…" } ?? "Downloading model…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(boundedProgress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(Theme.Typography.secondary)
            .foregroundStyle(Theme.Colors.ink2)

            ProgressView(value: boundedProgress)
                .accessibilityLabel(title)
                .accessibilityValue(
                    boundedProgress.formatted(.percent.precision(.fractionLength(0)))
                )
        }
        .frame(maxWidth: 280)
    }
}
