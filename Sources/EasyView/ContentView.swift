import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject private var library: ImageLibrary
    @State private var isDropTarget = false
    @State private var isFullScreen = false

    var body: some View {
        ZStack {
            // In full-screen viewer mode the native NavigationSplitView would
            // extend its sidebar divider into the temporary title bar shown
            // when the pointer reaches the top edge. Remove that split view
            // only for this state so the divider cannot appear there.
            if !(library.isViewerPresented && isFullScreen) {
                browser
            }

            if library.isViewerPresented,
               let selectedItem = library.selectedItem,
               !selectedItem.isDirectory {
                ImageViewer(isFullScreen: isFullScreen)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: library.isViewerPresented)
        .toolbar { toolbar }
        .background(WindowToolbarVisibilitySync(isFullScreen: $isFullScreen))
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: acceptDrop)
        .onOpenURL { url in
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                library.loadFolder(url)
            } else {
                library.openImageInContainingFolder(url)
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [10]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .alert("无法打开", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "未知错误")
        }
    }

    private var browser: some View {
        ZStack(alignment: .trailing) {
            NavigationSplitView {
                SidebarView(isFullScreen: isFullScreen)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
            } detail: {
                ThumbnailGridView(isFullScreen: isFullScreen)
                    .navigationSplitViewColumnWidth(min: 480, ideal: 760)
            }

            if library.showsInspector {
                InspectorView()
                    .frame(width: 290)
                    .background(.regularMaterial)
                    .shadow(color: .black.opacity(0.24), radius: 18, x: -5)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: library.showsInspector)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { library.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .disabled(!library.canGoBack)
            .help("上一步")

            Button { library.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .disabled(!library.canGoForward)
            .help("下一步")

            // Reserve a constant title slot so different directory names never
            // shift the trailing display, sort, and inspector controls.
            Text(library.folderURL?.lastPathComponent ?? "")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 220, alignment: .leading)

        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { library.isSlideshowPlaying.toggle() } label: {
                Image(systemName: library.isSlideshowPlaying ? "pause.fill" : "play.fill")
            }
            .help(library.isSlideshowPlaying ? "暂停自动播放" : "自动播放")
            .opacity(library.isViewerPresented ? 1 : 0)
            .disabled(!library.isViewerPresented)
            .accessibilityHidden(!library.isViewerPresented)

            Picker("显示方式", selection: $library.viewMode) {
                Label("缩略图", systemImage: "square.grid.2x2")
                    .tag(LibraryViewMode.thumbnails)
                Label("列表", systemImage: "list.bullet")
                    .tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented)
            .frame(width: 132)
            .help("切换列表与缩略图")

            Picker("排序", selection: $library.sort) {
                ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 105)

            Button { library.ascending.toggle() } label: {
                Image(systemName: library.ascending ? "arrow.up" : "arrow.down")
            }
            .help(library.ascending ? "升序" : "降序")

            Button { library.showsInspector.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help(library.showsInspector ? "关闭简介抽屉 (⌘I)" : "打开简介抽屉 (⌘I)")
        }
    }

    private func acceptDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    library.loadFolder(url)
                } else {
                    library.loadImages([url])
                }
            }
        }
        return true
    }
}

/// Keeps the app toolbar and the native window controls behaving as one unit:
/// both disappear in full screen and both return after leaving full screen.
private struct WindowToolbarVisibilitySync: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    final class Coordinator {
        private static var didApplyInitialWindowSize = false
        private weak var window: NSWindow?
        private var willEnterObserver: NSObjectProtocol?
        private var didExitObserver: NSObjectProtocol?
        private var isFullScreen: Binding<Bool>

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
        }

        func update(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
        }

        func attach(to window: NSWindow) {
            if self.window === window {
                hideNativeWindowTitle(in: window)
                alignTrailingToolbarItems(in: window.toolbar)
                return
            }
            detach()
            self.window = window

            // macOS may restore a much wider window from the previous run,
            // overriding WindowGroup.defaultSize. Apply the launch size once.
            if !Self.didApplyInitialWindowSize && !window.styleMask.contains(.fullScreen) {
                Self.didApplyInitialWindowSize = true
                window.setContentSize(NSSize(width: 1020, height: 700))
            }

            // This is a permanent window policy. Unlike NSToolbar, NSWindow is
            // not recreated when SwiftUI refreshes toolbar items during image
            // navigation, so the separator stays disabled after one setup.
            window.titlebarSeparatorStyle = .none
            window.toolbar?.showsBaselineSeparator = false
            hideNativeWindowTitle(in: window)
            alignTrailingToolbarItems(in: window.toolbar)

            let center = NotificationCenter.default
            willEnterObserver = center.addObserver(
                forName: NSWindow.willEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                self?.isFullScreen.wrappedValue = true
                window?.toolbar?.isVisible = false
            }
            didExitObserver = center.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                window?.toolbar?.isVisible = true
                self?.isFullScreen.wrappedValue = false
            }

            let currentlyFullScreen = window.styleMask.contains(.fullScreen)
            window.toolbar?.isVisible = !currentlyFullScreen
            if isFullScreen.wrappedValue != currentlyFullScreen {
                DispatchQueue.main.async { [weak self] in
                    self?.isFullScreen.wrappedValue = currentlyFullScreen
                }
            }
        }

        private func hideNativeWindowTitle(in window: NSWindow) {
            // SwiftUI supplies the app name as the WindowGroup's native title.
            // Clear it as well as hiding it so it cannot reappear in the
            // titlebar when the toolbar or window mode changes.
            window.titleVisibility = .hidden
            if !window.title.isEmpty { window.title = "" }
        }

        /// SwiftUI's toolbar groups do not automatically get a flexible gap
        /// after a custom navigation title. Add the native flexible item so
        /// the primary controls always stay flush with the trailing edge.
        private func alignTrailingToolbarItems(in toolbar: NSToolbar?) {
            guard let toolbar,
                  toolbar.items.count > 3,
                  !toolbar.items.contains(where: { $0.itemIdentifier == .flexibleSpace }) else {
                return
            }
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 3)
        }

        func detach() {
            let center = NotificationCenter.default
            if let willEnterObserver { center.removeObserver(willEnterObserver) }
            if let didExitObserver { center.removeObserver(didExitObserver) }
            willEnterObserver = nil
            didExitObserver = nil
            window = nil
        }

        deinit {
            detach()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isFullScreen: $isFullScreen)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(to: window)
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(isFullScreen: $isFullScreen)
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(to: window)
            }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }
}
