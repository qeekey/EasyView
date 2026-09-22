import AppKit
import SwiftUI

struct ImageViewer: View {
    @EnvironmentObject private var library: ImageLibrary
    let isFullScreen: Bool
    @State private var image: NSImage?
    @State private var zoom: CGFloat = 1
    @State private var rotation: Double = 0
    @State private var panOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize?

    var body: some View {
        ZStack {
            // Keep the unified title bar owned by the window toolbar so its
            // left title area has the same appearance as thumbnail browsing.
            Color(nsColor: NSColor(calibratedWhite: 0.075, alpha: 1))
                // In full screen there is no title bar to preserve. Cover the
                // top safe area too, so the browser beneath cannot show its
                // top divider through the viewer.
                .ignoresSafeArea(edges: isFullScreen ? .all : [.horizontal, .bottom])

            if let image {
                GeometryReader { geometry in
                    let viewport = CGSize(
                        width: max(1, geometry.size.width - 120),
                        height: max(1, geometry.size.height - 150)
                    )
                    let panLimit = panLimit(for: image, in: viewport)

                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: viewport.width, height: viewport.height)
                            .rotationEffect(.degrees(rotation))
                            .scaleEffect(zoom)
                            .offset(panOffset)
                    }
                    .frame(width: viewport.width, height: viewport.height)
                    // Keep the transformed image inside the content viewport,
                    // below the native window toolbar and above the controls.
                    .clipped()
                    .contentShape(Rectangle())
                    .position(
                        x: geometry.size.width / 2,
                        y: 60 + viewport.height / 2
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { setZoom($0) }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard zoom > 1 else { return }
                                let start = dragStartOffset ?? panOffset
                                dragStartOffset = start
                                panOffset = clampedOffset(
                                    CGSize(
                                        width: start.width + value.translation.width,
                                        height: start.height + value.translation.height
                                    ),
                                    limit: panLimit
                                )
                            }
                            .onEnded { _ in dragStartOffset = nil }
                    )
                    .onChange(of: zoom) { _ in
                        panOffset = clampedOffset(panOffset, limit: panLimit)
                    }
                    .onChange(of: rotation) { _ in
                        panOffset = clampedOffset(panOffset, limit: panLimit)
                    }
                }
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }

            viewerControls
            KeyboardCapture(
                onLeft: { library.selectPrevious() },
                onRight: { library.selectNext() },
                onUp: { library.selectPrevious() },
                onDown: { library.selectNext() },
                // Space advances in either regular or full-screen viewer mode.
                onSpace: { library.selectNext() },
                onEscape: { library.isViewerPresented = false }
            )
            .frame(width: 0, height: 0)
        }
        .task(id: library.selectedURL) { loadFullImage() }
        .onChange(of: library.selectedURL) { _ in
            zoom = 1
            rotation = 0
            panOffset = .zero
        }
        .task(id: library.isSlideshowPlaying ? library.slideshowInterval : 0) {
            guard library.isSlideshowPlaying else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(library.slideshowInterval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                library.selectNext()
            }
        }
        .onDisappear { library.isSlideshowPlaying = false }
    }

    private var viewerControls: some View {
        VStack {
            HStack(spacing: 12) {
                Button { library.isViewerPresented = false } label: {
                    Label("返回浏览", systemImage: "chevron.left")
                }
                .buttonStyle(ViewerButtonStyle())

                Spacer()

                if library.showsThumbnailFileName, let item = library.selectedItem {
                    Text(item.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                }

                Spacer()
            }
            .padding(16)

            Spacer()

            HStack(spacing: 10) {
                Button { library.selectPrevious() } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Divider().frame(height: 18).overlay(.white.opacity(0.25))
                Button { setZoom(zoom - 0.2) } label: { Image(systemName: "minus.magnifyingglass") }
                Text("\(Int(zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 46)
                Button { setZoom(zoom + 0.2) } label: { Image(systemName: "plus.magnifyingglass") }
                Button { setZoom(1) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("适合窗口")
                Divider().frame(height: 18).overlay(.white.opacity(0.25))
                Button { rotate(by: -90) } label: { Image(systemName: "rotate.left") }
                Button { rotate(by: 90) } label: { Image(systemName: "rotate.right") }
                Divider().frame(height: 18).overlay(.white.opacity(0.25))
                Button { library.moveSelectedItemToTrash() } label: { Image(systemName: "trash") }
                    .help("移到废纸篓")
                Divider().frame(height: 18).overlay(.white.opacity(0.25))
                Button { library.selectNext() } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(ViewerButtonStyle())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(.ultraThinMaterial.opacity(0.85), in: Capsule())
            .padding(.bottom, 18)
        }
    }

    private func loadFullImage() {
        guard let url = library.selectedURL else { image = nil; return }
        image = NSImage(contentsOf: url)
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 1), 8)
        if zoom == 1 { panOffset = .zero }
    }

    private func rotate(by degrees: Double) {
        rotation += degrees
        panOffset = .zero
    }

    private func panLimit(for image: NSImage, in viewport: CGSize) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return .zero }

        let fitScale = min(viewport.width / image.size.width, viewport.height / image.size.height)
        var displayedSize = CGSize(
            width: image.size.width * fitScale * zoom,
            height: image.size.height * fitScale * zoom
        )
        if Int(abs(rotation).truncatingRemainder(dividingBy: 180)) == 90 {
            displayedSize = CGSize(width: displayedSize.height, height: displayedSize.width)
        }
        return CGSize(
            width: max(0, (displayedSize.width - viewport.width) / 2),
            height: max(0, (displayedSize.height - viewport.height) / 2)
        )
    }

    private func clampedOffset(_ offset: CGSize, limit: CGSize) -> CGSize {
        CGSize(
            width: min(max(offset.width, -limit.width), limit.width),
            height: min(max(offset.height, -limit.height), limit.height)
        )
    }
}

private struct ViewerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(8)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? .white.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct KeyboardCapture: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onUp: () -> Void
    let onDown: () -> Void
    let onSpace: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handlers = (onLeft, onRight, onUp, onDown, onSpace, onEscape)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.handlers = (onLeft, onRight, onUp, onDown, onSpace, onEscape)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    final class KeyView: NSView {
        var handlers: (() -> Void, () -> Void, () -> Void, () -> Void, () -> Void, () -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: handlers?.0()
            case 124: handlers?.1()
            case 126: handlers?.2()
            case 125: handlers?.3()
            case 49: handlers?.4()
            case 53: handlers?.5()
            default: super.keyDown(with: event)
            }
        }
    }
}
