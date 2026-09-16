import AppKit
import SwiftUI

/// 이름 편집 창. SwiftUI 뷰를 NSWindow에 담는다.
final class RenameWindowController {
    private let spaces: SpaceManager
    private let names: NameStore
    private let settings: AppSettings
    private var window: NSWindow?

    init(spaces: SpaceManager, names: NameStore, settings: AppSettings) {
        self.spaces = spaces
        self.names = names
        self.settings = settings
    }

    func show() {
        if window == nil {
            let view = RenameView(spaces: spaces, names: names, settings: settings) { [weak self] in
                self?.window?.close()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable]
            window.title = "데스크탑 이름"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        spaces.refresh()
        spaces.refreshApps()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct RenameView: View {
    @ObservedObject var spaces: SpaceManager
    @ObservedObject var names: NameStore
    @ObservedObject var settings: AppSettings
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) {
                ForEach(Array(spaces.spaces.enumerated()), id: \.element.id) { index, space in
                    row(for: space)
                    if index < spaces.spaces.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.black.opacity(0.14), lineWidth: 0.5))

            Text("이름을 비우면 기본 이름(데스크탑 N)으로 돌아갑니다. 이름은 공간의 고유 ID에 저장되어 순서를 바꿔도 따라갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Mission Control에 이름 겹쳐 보이기", isOn: $settings.overlayEnabled)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("완료", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
    }

    @ViewBuilder
    private func row(for space: Space) -> some View {
        let apps = spaces.apps(in: space)
        HStack(alignment: .top, spacing: 12) {
            Text(space.number.map { String($0) } ?? "—")
                .font(.system(.body, design: .default).monospacedDigit())
                .foregroundStyle(space.isActive ? Color.accentColor : Color.secondary)
                .frame(width: 20, alignment: .leading)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 6) {
                TextField(space.defaultName, text: binding(for: space))
                    .textFieldStyle(.roundedBorder)
                    .disabled(space.isFullscreen)

                HStack(spacing: 6) {
                    ForEach(apps.prefix(6)) { app in
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 16, height: 16)
                        }
                    }
                    Text(apps.isEmpty ? "열린 창 없음" : WindowInspector.summary(for: apps, maxNames: 4))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(height: 16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func binding(for space: Space) -> Binding<String> {
        Binding(
            get: { names.names[space.uuid] ?? "" },
            set: { names.setName($0, for: space) }
        )
    }
}
