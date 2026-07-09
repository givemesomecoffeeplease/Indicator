import SwiftUI
import Combine

// ObservableObject 사용: @Observable(Observation)은 macOS 14+ 전용이라
// macOS 12~13 기기 호환을 위해 하위 호환 API로 유지
class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private init() {}

    // 미설정(object == nil)과 사용자가 저장한 0(사용 안 함)을 구분해서 읽음
    private static func stored(_ key: String, default def: Int, max maxV: Int) -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else { return def }
        return min(max(UserDefaults.standard.integer(forKey: key), 0), maxV)
    }

    // 카운트다운 표시 시작: 0(사용 안 함), 1, 2마디 전 (기본 2)
    @Published var countdownBars: Int = stored("countdownBars", default: 2, max: 2) {
        didSet { UserDefaults.standard.set(countdownBars, forKey: "countdownBars") }
    }

    // 슬라이드 조기 전환: 팔분음표 N개만큼 먼저 전환, 0 = 사용 안 함 (기본 3)
    @Published var slideEarlyEighths: Int = stored("slideEarlyEighths", default: 3, max: 16) {
        didSet { UserDefaults.standard.set(slideEarlyEighths, forKey: "slideEarlyEighths") }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared

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
                detail: settings.slideEarlyEighths == 0 ? "사용 안 함" : "팔분음표 \(settings.slideEarlyEighths)개 먼저",
                caption: settings.slideEarlyEighths == 0
                    ? "슬라이드가 원래 마디 시작에 맞춰 전환됩니다."
                    : "같은 섹션 안의 슬라이드가 팔분음표 \(settings.slideEarlyEighths)개만큼 일찍 전환됩니다. (섹션 첫 슬라이드는 정각 전환)"
            ) {
                Stepper("", value: $settings.slideEarlyEighths, in: 0...16)
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
