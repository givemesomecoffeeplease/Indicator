import SwiftUI

// 카운트다운 표시 시작은 곡별로 가사 편집 화면에서 설정함 (LyricsStore.countdownBars) —
// 전역 설정이었던 SettingsStore.countdownBars/slideEarlyEighths는 모두 제거됨.
struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("카운트다운 표시 시작은 이제 곡별로 설정해요.")
                .fontWeight(.medium)
            Text("가사 편집 화면에서 곡을 선택하면 곡 제목 옆에 카운트다운 설정이 있어요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
