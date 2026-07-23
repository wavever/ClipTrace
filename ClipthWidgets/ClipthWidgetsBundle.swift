import WidgetKit
import SwiftUI

/// Entry point for the Clipth widget extension. Exposes the two stat widgets
/// — 数据 (library composition) and 活跃统计 (copy activity) — both reading the
/// snapshot the app writes into the shared App Group container.
@main
struct ClipthWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DataWidget()
        ActivityWidget()
    }
}
