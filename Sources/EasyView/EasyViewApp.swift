import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var aboutPanel: NSPanel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app has no text-editing surface, so the system Edit menu would
        // only contain irrelevant disabled commands.
        DispatchQueue.main.async {
            guard let mainMenu = NSApp.mainMenu,
                  let editMenu = mainMenu.items.first(where: {
                      $0.title == "编辑" || $0.title == "Edit"
                  }) else { return }
            mainMenu.removeItem(editMenu)
        }
    }

    func showAboutPanel() {
        if let aboutPanel {
            aboutPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 246),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "关于简图"
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView:
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                Text("简图")
                    .font(.title2.weight(.semibold))
                Text("版本 0.1.0")
                    .font(.body)
                Text("版权所有 © 2026 qeekey")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        aboutPanel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct EasyViewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = ImageLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1020, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于简图") {
                    appDelegate.showAboutPanel()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("打开文件夹…") { library.chooseFolder() }
                    .keyboardShortcut("o")
                Button("打开图片…") { library.chooseImages() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("查看") {
                Button("上一张") { library.navigate(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("下一张") { library.navigate(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("上一张（向上）") { library.navigate(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("下一张（向下）") { library.navigate(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Divider()
                Button("预览选中图片") {
                    library.openSelectedItem()
                }
                    .keyboardShortcut(.space, modifiers: [])
                Button("显示简介") { library.showsInspector.toggle() }
                    .keyboardShortcut("i")
            }
            CommandMenu("选项") {
                Toggle("显示文件名", isOn: $library.showsThumbnailFileName)
                Toggle("文件名搜索", isOn: $library.showsFileNameSearch)
                Divider()
                Picker("播放间隔", selection: $library.slideshowInterval) {
                    Text("2 秒").tag(2.0)
                    Text("3 秒").tag(3.0)
                    Text("5 秒").tag(5.0)
                }
                Divider()
                Toggle("显示子目录", isOn: $library.showsSubdirectories)
            }
        }
    }
}
