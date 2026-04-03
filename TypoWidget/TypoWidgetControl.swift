//
//  TypoWidgetControl.swift
//  TypoWidget
//
//  Created by xiaorsz on 2026/3/21.
//

import AppIntents
import SwiftUI
import WidgetKit

@available(iOSApplicationExtension 18.0, *)
struct TypoWidgetControl: ControlWidget {
    static let kind: String = "cc.xiaorsz.typo-review.TypoWidget"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: Provider()
        ) { value in
            ControlWidgetToggle(
                "Start Timer",
                isOn: value.isRunning,
                action: StartTimerIntent(value.name)
            ) { isRunning in
                Label(isRunning ? "开启" : "关闭", systemImage: "timer")
            }
        }
        .displayName("Timer")
        .description("A an example control that runs a timer.")
    }
}

@available(iOSApplicationExtension 18.0, *)
extension TypoWidgetControl {
    @available(iOSApplicationExtension 18.0, *)
    struct Value {
        var isRunning: Bool
        var name: String
    }

    @available(iOSApplicationExtension 18.0, *)
    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: TimerConfiguration) -> Value {
            TypoWidgetControl.Value(isRunning: false, name: configuration.timerName)
        }

        func currentValue(configuration: TimerConfiguration) async throws -> Value {
            let isRunning = true // Check if the timer is running
            return TypoWidgetControl.Value(isRunning: isRunning, name: configuration.timerName)
        }
    }
}

@available(iOSApplicationExtension 18.0, *)
struct TimerConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Timer Name Configuration"

    @Parameter(title: "Timer Name", default: "Timer")
    var timerName: String
}

@available(iOSApplicationExtension 18.0, *)
struct StartTimerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Start a timer"

    @Parameter(title: "Timer Name")
    var name: String

    @Parameter(title: "Timer is running")
    var value: Bool

    init() {}

    init(_ name: String) {
        self.name = name
    }

    func perform() async throws -> some IntentResult {
        // Start the timer…
        return .result()
    }
}
