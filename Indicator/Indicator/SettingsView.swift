import SwiftUI
import Observation

@Observable
class SettingsStore {
    static let shared = SettingsStore()
    private init() {}

    var countdownBars: Int = {
        let v = UserDefaults.standard.integer(forKey: "countdownBars")
        if v == 0 { return 2 }        // 미설정이면 기본 2마디
        return min(v, 2)              // 0(비활성), 1, 2마디만 유효
    }() {
        didSet { UserDefaults.standard.set(countdownBars, forKey: "countdownBars") }
    }

    // 슬라이드 조기 전환: 전 마디의 N번째 팔분음표에서 전환 (기본 3)
    var slideEarlyEighths: Int = UserDefaults.standard.integer(forKey: "slideEarlyEighths").nonZero ?? 3 {
        didSet { UserDefaults.standard.set(slideEarlyEighths, forKey: "slideEarlyEighths") }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

struct SettingsView: View {
    @State private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            settingRow(
                label: "카운트다운 표시 시작",
                detail: settings.countdownBars == 0 ? "사용 안 함" : "\(settings.countdownBars)마디 전",
                caption: settings.countdownBars == 0
                    ? "카운트다운이 표시되지 않습니다."
                    : "사전 스캔 후 다음 섹션 전환 \(settings.countdownBars)마디 전부터 표시됩니다."
            ) {
                Stepper("", value: $settings.countdownBars, in: 0...2)
                    .labelsHidden()
            }

            Divider()

            settingRow(
                label: "슬라이드 조기 전환",
                detail: "전 마디 \(settings.slideEarlyEighths)번째 팔분음표",
                caption: "슬라이드를 원래 마디 시작보다 일찍 전환합니다. (스캔 후 적용)"
            ) {
                Stepper("", value: $settings.slideEarlyEighths, in: 1...16)
                    .labelsHidden()
            }
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private func settingRow<C: View>(label: String, detail: String, caption: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label).fontWeight(.medium)
                    Text(detail).foregroundStyle(.secondary)
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
