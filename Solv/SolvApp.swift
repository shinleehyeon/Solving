import SwiftUI

@main
struct SolvApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            Text(appState.statusText)
                .font(.caption)

            Divider()

            SettingsLink {
                Text("설정…")
            }

            Divider()

            Menu("실행") {
                Section("Caps Lock") {
                    Button("영역 · 회색선") {
                        Task { await appState.solve(capture: .region, output: .capsLock, showBorder: true) }
                    }
                    Button("영역 · 선 없음") {
                        Task { await appState.solve(capture: .region, output: .capsLock, showBorder: false) }
                    }
                    Button("전체 화면") {
                        Task { await appState.solve(capture: .fullScreen, output: .capsLock) }
                    }
                }
                Section("마우스") {
                    Button("영역 · 회색선") {
                        Task { await appState.solve(capture: .region, output: .mouse, showBorder: true) }
                    }
                    Button("영역 · 선 없음") {
                        Task { await appState.solve(capture: .region, output: .mouse, showBorder: false) }
                    }
                    Button("전체 화면") {
                        Task { await appState.solve(capture: .fullScreen, output: .mouse) }
                    }
                }
                Section("클립보드 (Raycast ⌘V)") {
                    Button("영역 · 회색선") {
                        Task { await appState.solve(capture: .region, output: .raycast, showBorder: true) }
                    }
                    Button("영역 · 선 없음") {
                        Task { await appState.solve(capture: .region, output: .raycast, showBorder: false) }
                    }
                    Button("전체 화면") {
                        Task { await appState.solve(capture: .fullScreen, output: .raycast) }
                    }
                }
            }
            .disabled(appState.isBusy)

            Menu("단축키") {
                Section("Caps") {
                    Text("⌘⌥ — 영역 · 회색선")
                    Text("⌘⌥⌃ — 영역 · 선 없음")
                    Text("⌘⌥C — 전체")
                }
                Section("마우스") {
                    Text("⌘⌃ — 영역 · 회색선")
                    Text("⌘⌥⌃Fn — 영역 · 선 없음")
                    Text("⌘⌃C — 전체")
                }
                Section("클립보드") {
                    Text("⌘⇧ — 영역 · 회색선")
                    Text("⌘⇧⌥ — 영역 · 선 없음")
                    Text("⌘⇧C — 전체")
                    Text("복사만 · Raycast는 직접 연 뒤 ⌘V")
                }
            }

            Divider()

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

            Menu("도구") {
                Button("API 키 설정…") {
                    appState.promptForAPIKey()
                }
                Button("화면 녹화 다시 연결…") {
                    appState.showPermissionRepairGuide()
                }
                Button("캡처 진단…") {
                    Task { await appState.runCaptureDiagnose() }
                }
                Divider()
                Button("Caps Lock 테스트 (2회)") {
                    Task { await appState.testCapsLock() }
                }
                Button("마우스 이동 테스트") {
                    Task { await appState.testMouseMove() }
                }
                Button("클립보드 테스트") {
                    Task { await appState.testRaycastType() }
                }
                Button("마지막 전송 이미지 열기") {
                    appState.openLastCaptureImage()
                }
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
