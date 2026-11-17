import AppKit
import WidgetKit
WidgetCenter.shared.reloadAllTimelines()
RunLoop.main.run(until: .now + 1)
NSApplication.shared.terminate(nil)
