import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var library: ImageLibrary
    let isFullScreen: Bool

    var body: some View {
        List {
            Section("位置") {
                SidebarButton(title: "图片", icon: "photo.on.rectangle", url: FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first)
                SidebarButton(title: "桌面", icon: "desktopcomputer", url: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first)
                SidebarButton(title: "下载", icon: "arrow.down.circle", url: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
            }
            Section("当前") {
                if let folder = library.folderURL {
                    Label(folder.lastPathComponent, systemImage: "folder.fill")
                        .lineLimit(1)
                        .help(folder.path)
                } else if !library.items.isEmpty {
                    Label("已选图片", systemImage: "photo.stack")
                } else {
                    Text("尚未打开文件夹")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    library.chooseFolder()
                } label: {
                    Label("其他文件夹…", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            // A NavigationSplitView sidebar intentionally extends beneath the
            // unified macOS title bar. Reserve that area so the first section
            // and directory rows are never hidden behind the toolbar.
            Color.clear.frame(height: isFullScreen ? 0 : 40)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "photo")
                Text("\(library.filteredItems.count) 张图片")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
        }
    }

    private struct SidebarButton: View {
        @EnvironmentObject private var library: ImageLibrary
        let title: String
        let icon: String
        let url: URL?

        var body: some View {
            Button {
                if let url { library.loadFolder(url) }
            } label: {
                Label(title, systemImage: icon)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }
}

struct ThumbnailGridView: View {
    @EnvironmentObject private var library: ImageLibrary
    let isFullScreen: Bool

    var body: some View {
        VStack(spacing: 0) {
            if library.showsFileNameSearch {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("按文件名搜索", text: $library.searchText)
                        .textFieldStyle(.plain)
                    if !library.searchText.isEmpty {
                        Button { library.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(.bar)

                Divider()
            }

            if library.isLoading {
                Spacer()
                ProgressView("正在读取图片…")
                Spacer()
            } else if library.filteredItems.isEmpty {
                emptyState
            } else {
                switch library.viewMode {
                case .thumbnails:
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: library.thumbnailSize), spacing: 14)], spacing: 18) {
                            ForEach(library.filteredItems) { item in
                                ThumbnailCell(item: item, size: library.thumbnailSize)
                                    .onTapGesture(count: 2) {
                                        library.selectedURL = item.url
                                        library.isViewerPresented = true
                                    }
                                    .onTapGesture {
                                        library.selectedURL = item.url
                                    }
                            }
                        }
                        .padding(18)
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                case .list:
                    ImageListView()
                }
            }

            Divider()
            HStack {
                Text(library.folderURL?.path ?? "已选图片")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if library.viewMode == .thumbnails {
                    Image(systemName: "photo")
                    Slider(value: $library.thumbnailSize, in: 90...230)
                        .frame(width: 120)
                    Image(systemName: "photo.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.bar)
        }
        .padding(.top, isFullScreen ? 0 : 40)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text(library.items.isEmpty ? "这里还没有图片" : "没有匹配的图片")
                .font(.title3.weight(.medium))
            Text(library.items.isEmpty ? "打开文件夹，或把图片拖到窗口中" : "试试其他搜索词")
                .foregroundStyle(.secondary)
            if library.items.isEmpty {
                Button("打开文件夹…") { library.chooseFolder() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ImageListView: View {
    @EnvironmentObject private var library: ImageLibrary
    @State private var columnWidths = ListColumnWidths()

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { scrollProxy in
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("image-list-top")
                        listHeader
                        Divider()
                        LazyVStack(spacing: 0) {
                            ForEach(Array(library.filteredItems.enumerated()), id: \.element.id) { index, item in
                                ImageListRow(
                                    item: item,
                                    columnWidths: columnWidths,
                                    hasAlternateBackground: index.isMultiple(of: 2) == false
                                )
                                    .onTapGesture(count: 2) {
                                        library.selectedURL = item.url
                                        library.isViewerPresented = true
                                    }
                                    .onTapGesture {
                                        library.selectedURL = item.url
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(
                        minWidth: max(columnWidths.contentWidth + 24, viewport.size.width),
                        minHeight: viewport.size.height,
                        alignment: .topLeading
                    )
                }
                .onChange(of: library.folderURL) { _ in
                    scrollProxy.scrollTo("image-list-top", anchor: .topLeading)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var listHeader: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 44)
                .overlay(alignment: .trailing) { ListColumnDivider(isHeader: true) }
            ResizableColumnHeader("名称", width: $columnWidths.name, minimum: 120, alignment: .leading, sort: .name, currentSort: library.sort, ascending: library.ascending) {
                library.sort(by: .name)
            }
            ResizableColumnHeader("类型", width: $columnWidths.type, minimum: 54, alignment: .leading, sort: .type, currentSort: library.sort, ascending: library.ascending) {
                library.sort(by: .type)
            }
            ResizableColumnHeader("尺寸", width: $columnWidths.dimensions, minimum: 82, alignment: .leading, sort: .dimensions, currentSort: library.sort, ascending: library.ascending) {
                library.sort(by: .dimensions)
            }
            ResizableColumnHeader("大小", width: $columnWidths.size, minimum: 60, alignment: .trailing, sort: .size, currentSort: library.sort, ascending: library.ascending) {
                library.sort(by: .size)
            }
            ResizableColumnHeader("修改日期", width: $columnWidths.modifiedAt, minimum: 110, alignment: .leading, sort: .date, currentSort: library.sort, ascending: library.ascending) {
                library.sort(by: .date)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.bar)
    }
}

private struct ImageListRow: View {
    @EnvironmentObject private var library: ImageLibrary
    let item: ImageItem
    let columnWidths: ListColumnWidths
    let hasAlternateBackground: Bool
    @State private var image: NSImage?

    private var isSelected: Bool { library.selectedURL == item.url }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 44, height: 36)

            Text(item.name)
                .lineLimit(1)
                .frame(width: columnWidths.name, alignment: .leading)
            Text(item.fileExtension)
                .frame(width: columnWidths.type, alignment: .leading)
            Text(item.dimensionsText)
                .frame(width: columnWidths.dimensions, alignment: .leading)
            Text(item.sizeText)
                .frame(width: columnWidths.size, alignment: .trailing)
            Text(item.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                .lineLimit(1)
                .frame(width: columnWidths.modifiedAt, alignment: .leading)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : (hasAlternateBackground ? Color(nsColor: NSColor(srgbRed: 247.0 / 255.0, green: 247.0 / 255.0, blue: 247.0 / 255.0, alpha: 1)) : .clear)
        )
        .contentShape(Rectangle())
        .task(id: item.url) {
            image = ThumbnailCache.shared.image(for: item.url, maxPixelSize: 120)
        }
    }
}

private struct ListColumnWidths {
    var name: CGFloat = 280
    var type: CGFloat = 70
    var dimensions: CGFloat = 104
    var size: CGFloat = 78
    var modifiedAt: CGFloat = 142

    var contentWidth: CGFloat {
        44 + name + type + dimensions + size + modifiedAt + (12 * 5)
    }
}

private struct ResizableColumnHeader: View {
    let title: String
    @Binding var width: CGFloat
    let minimum: CGFloat
    let alignment: Alignment
    let sort: LibrarySort
    let currentSort: LibrarySort
    let ascending: Bool
    let onSort: () -> Void
    @State private var startingWidth: CGFloat?

    init(
        _ title: String,
        width: Binding<CGFloat>,
        minimum: CGFloat,
        alignment: Alignment,
        sort: LibrarySort,
        currentSort: LibrarySort,
        ascending: Bool,
        onSort: @escaping () -> Void
    ) {
        self.title = title
        _width = width
        self.minimum = minimum
        self.alignment = alignment
        self.sort = sort
        self.currentSort = currentSort
        self.ascending = ascending
        self.onSort = onSort
    }

    var body: some View {
        ZStack {
            // An explicit full-width hit target keeps sorting reliable across
            // the entire header cell, including its otherwise empty space.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onSort)

            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                if currentSort == sort {
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        .imageScale(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .allowsHitTesting(false)
        }
        .frame(width: width, alignment: alignment)
        .contentShape(Rectangle())
        .help("点击按\(title)排序；拖动右侧分割线调整列宽")
            .overlay(alignment: .trailing) {
                ZStack {
                    ListColumnDivider(isHeader: true)
                    Color.clear
                        .frame(width: 10)
                        .contentShape(Rectangle())
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.resizeLeftRight.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let initialWidth = startingWidth ?? width
                                    startingWidth = initialWidth
                                    width = max(minimum, initialWidth + value.translation.width)
                                }
                                .onEnded { _ in startingWidth = nil }
                        )
                }
            }
    }
}

private struct ListColumnDivider: View {
    var isHeader = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(isHeader ? 0.9 : 0.55))
            .frame(width: 1, height: isHeader ? 22 : 32)
    }
}

struct ThumbnailCell: View {
    @EnvironmentObject private var library: ImageLibrary
    let item: ImageItem
    let size: Double
    @State private var image: NSImage?

    var isSelected: Bool { library.selectedURL == item.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black.opacity(isSelected ? 0.09 : 0))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(5)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: max(82, size * 0.72))

            if library.showsThumbnailFileName {
                Text(item.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
            }
        }
        .contentShape(Rectangle())
        .task(id: item.url) {
            image = ThumbnailCache.shared.image(for: item.url, maxPixelSize: max(size * 2, 320))
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject private var library: ImageLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("简介").font(.headline)
                Spacer()
                Button { library.showsInspector = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .padding(14)
            Divider()

            if let item = library.selectedItem {
                ScrollView {
                    VStack(spacing: 16) {
                        PreviewImage(url: item.url)
                            .frame(height: 170)
                            .padding(.top, 16)
                        Text(item.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)

                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 11) {
                            row("种类", item.fileExtension)
                            row("尺寸", item.dimensionsText)
                            row("大小", item.sizeText)
                            if let date = item.modifiedAt {
                                row("修改", date.formatted(date: .abbreviated, time: .shortened))
                            }
                            row("位置", item.url.deletingLastPathComponent().path)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "info.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("未选择图片").font(.headline)
                    Text("点选一张图片以查看信息")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}

struct PreviewImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            image = ThumbnailCache.shared.image(for: url, maxPixelSize: 700)
        }
    }
}
