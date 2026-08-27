import SwiftUI

@main
struct SolvApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            Text(appState.statusText)
                .font(.caption)

            Divider()

            Button("Caps · 영역 (⌘⌥)") {
                Task { await appState.solve(capture: .region, output: .capsLock, showBorder: true) }
            }
            .disabled(appState.isBusy)

            Button("Caps · 영역 숨김선 (⌘⌥⌃)") {
                Task { await appState.solve(capture: .region, output: .capsLock, showBorder: false) }
            }
            .disabled(appState.isBusy)

            Button("Caps · 전체 (⌘⌥C)") {
                Task { await appState.solve(capture: .fullScreen, output: .capsLock) }
            }
            .disabled(appState.isBusy)

            Button("마우스 · 영역 (⌘⌃)") {
                Task { await appState.solve(capture: .region, output: .mouse, showBorder: true) }
            }
            .disabled(appState.isBusy)

            Button("마우스 · 영역 숨김선 (⌘⌥⌃Fn)") {
                Task { await appState.solve(capture: .region, output: .mouse, showBorder: false) }
            }
            .disabled(appState.isBusy)

            Button("마우스 · 전체 (⌘⌃C)") {
                Task { await appState.solve(capture: .fullScreen, output: .mouse) }
            }
            .disabled(appState.isBusy)

            Toggle("단축키 사용", isOn: $appState.hotkeyEnabled)

            Menu("모델: \(appState.selectedModel.title)") {
                ForEach(SolvModelTier.allCases) { tier in
                    Section(tier.title) {
                        ForEach(SolvModel.models(for: tier)) { model in
                            Button {
                                appState.selectedModel = model
                            } label: {
                                Text(model == appState.selectedModel ? "✓ \(model.title)" : model.title)
                            }
                        }
                    }
                }
            }

            Divider()

            Button("API 키 설정…") {
                appState.promptForAPIKey()
            }

            Button("화면 녹화 다시 연결…") {
                appState.showPermissionRepairGuide()
            }

            Button("캡처 진단…") {
                Task { await appState.runCaptureDiagnose() }
            }

            Button("Caps Lock 테스트 (2회)") {
                Task { await appState.testCapsLock() }
            }

            Button("마우스 이동 테스트") {
                Task { await appState.testMouseMove() }
            }

            Button("마지막 전송 이미지 열기") {
                appState.openLastCaptureImage()
            }

            Divider()

            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: appState.isBusy ? "circle.dotted" : "eye")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(appState: appState)
        }
    }
}
