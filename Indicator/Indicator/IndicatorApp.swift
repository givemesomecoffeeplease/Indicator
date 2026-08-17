import SwiftUI

@main
struct IndicatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // LSUIElement 앱(Dock 아이콘·표준 메뉴 없음)이라 이 Settings 씬은 시스템에서 열릴 경로가
    // 없다 — SwiftUI App 프로토콜이 Scene을 최소 하나 요구해서 자리만 채우는 용도.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
