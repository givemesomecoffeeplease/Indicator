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
    // 슬라이드 조기 전환(slideEarlyEighths)은 MTC 시간 기반 찍기 개편으로 제거됨 —
    // 전환 시점은 사용자가 찍은 순간 그 자체가 정답이라 보정 개념이 없음
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
