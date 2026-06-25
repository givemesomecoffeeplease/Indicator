import SwiftUI
import Observation

@Observable
class SettingsStore {
    static let shared = SettingsStore()
    private init() {}

    var countdownBars: Int = UserDefaults.standard.integer(forKey: "countdownBars").nonZero ?? 1 {
        didSet { UserDefaults.standard.set(countdownBars, forKey: "countdownBars") }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

struct SettingsView: View {
    @State private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Stepper("카운트다운 표시 시작: \(settings.countdownBars)마디 전",
                    value: $settings.countdownBars, in: 1...8)
                .padding(.vertical, 4)

            Text("다음 섹션 전환 \(settings.countdownBars)마디 전부터 카운트다운 숫자가 표시됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 400, height: 120)
    }
}
