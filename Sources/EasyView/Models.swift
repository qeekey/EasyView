import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageItem: Identifiable, Hashable {
    let url: URL
    let width: Int
    let height: Int
    let fileSize: Int64
    let modifiedAt: Date?
    let isDirectory: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var fileExtension: String { isDirectory ? "文件夹" : url.pathExtension.uppercased() }
    var dimensionsText: String { isDirectory ? "--" : (width > 0 ? "\(width) × \(height)" : "—") }
    var sizeText: String { isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        fileSize = Int64(values?.fileSize ?? 0)
        modifiedAt = values?.contentModificationDate
        var directory = ObjCBool(false)
        FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        isDirectory = directory.boolValue

        guard !isDirectory else {
            width = 0
            height = 0
            return
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            width = 0
            height = 0
            return
        }
        width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case name = "名称"
    case type = "类型"
    case date = "修改日期"
    case size = "文件大小"
    case dimensions = "尺寸"
    var id: String { rawValue }
}

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case thumbnails = "缩略图"
    case list = "列表"
    var id: String { rawValue }
}

enum ImageNavigationDirection {
    case left
    case right
    case up
    case down
}

@MainActor
final class ImageLibrary: ObservableObject {
    @Published var folderURL: URL?
    @Published var items: [ImageItem] = [] {
        didSet { rebuildFilteredItems() }
    }
    @Published var selectedURL: URL?
    @Published var searchText = "" {
        didSet { rebuildFilteredItems() }
    }
    @Published var sort: LibrarySort = .name {
        didSet { rebuildFilteredItems() }
    }
    @Published var ascending = true {
        didSet { rebuildFilteredItems() }
    }
    @Published private(set) var filteredItems: [ImageItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isViewerPresented = false
    @Published var isSlideshowPlaying = false
    @Published var showsInspector = false
    @Published var thumbnailSize: Double = 150
    @Published var viewMode: LibraryViewMode = .thumbnails
    private var thumbnailColumnCount = 1
    @Published var showsThumbnailFileName: Bool = UserDefaults.standard.object(forKey: "showsThumbnailFileName") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsThumbnailFileName, forKey: "showsThumbnailFileName") }
    }
    @Published var slideshowInterval: Double = UserDefaults.standard.object(forKey: "slideshowInterval") as? Double ?? 3 {
        didSet { UserDefaults.standard.set(slideshowInterval, forKey: "slideshowInterval") }
    }
    @Published var showsFileNameSearch: Bool = UserDefaults.standard.object(forKey: "showsFileNameSearch") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsFileNameSearch, forKey: "showsFileNameSearch")
            if !showsFileNameSearch { searchText = "" }
        }
    }
    @Published var showsSubdirectories: Bool = UserDefaults.standard.object(forKey: "showsSubdirectories") as? Bool
        ?? UserDefaults.standard.object(forKey: "recursivelyShowsSubdirectories") as? Bool
        ?? false {
        didSet {
            UserDefaults.standard.set(showsSubdirectories, forKey: "showsSubdirectories")
            reloadCurrentFolder()
        }
    }

    private let supportedExtensions = Set(["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp"])
    private var loadToken = UUID()
    private var folderHistory: [URL] = []
    private var folderHistoryIndex = -1

    var canGoBack: Bool { folderHistoryIndex > 0 }
    var canGoForward: Bool { folderHistoryIndex >= 0 && folderHistoryIndex < folderHistory.count - 1 }

    /// Rebuild only when the collection, search text, or sort order changes.
    /// Selecting an image should not make a large folder sort again.
    private func rebuildFilteredItems() {
        let searched = searchText.isEmpty ? items : items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
        filteredItems = searched.sorted { first, second in
            let lhs = ascending ? first : second
            let rhs = ascending ? second : first
            switch sort {
            case .name:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .type:
                let typeOrder = lhs.fileExtension.localizedCaseInsensitiveCompare(rhs.fileExtension)
                return typeOrder == .orderedSame
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : typeOrder == .orderedAscending
            case .date:
                return (lhs.modifiedAt ?? .distantPast) < (rhs.modifiedAt ?? .distantPast)
            case .size:
                return (lhs.isDirectory ? 0 : lhs.fileSize) < (rhs.isDirectory ? 0 : rhs.fileSize)
            case .dimensions:
                return (lhs.isDirectory ? 0 : lhs.width * lhs.height) < (rhs.isDirectory ? 0 : rhs.width * rhs.height)
            }
        }
    }

    var selectedItem: ImageItem? {
        guard let selectedURL else { return nil }
        return items.first { $0.url == selectedURL }
    }

    init() {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        if let pictures, FileManager.default.fileExists(atPath: pictures.path) {
            loadFolder(pictures)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择图片文件夹"
        panel.prompt = "打开"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadFolder(url) }
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.title = "选择图片"
        panel.prompt = "打开"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            loadImages(panel.urls)
        }
    }

    func loadFolder(
        _ url: URL,
        selecting requestedSelection: URL? = nil,
        presentingViewer: Bool = false,
        recordingHistory: Bool = true
    ) {
        if recordingHistory { recordFolderVisit(url) }
        folderURL = url
        isLoading = true
        errorMessage = nil
        let extensions = supportedExtensions
        let showsSubdirectories = showsSubdirectories
        let token = UUID()
        loadToken = token
        Task.detached(priority: .userInitiated) {
            do {
                let urls = try Self.folderItems(
                    in: url,
                    showsSubdirectories: showsSubdirectories,
                    supportedExtensions: extensions
                )
                let loaded = urls.map(ImageItem.init)
                await MainActor.run {
                    guard self.loadToken == token else { return }
                    self.items = loaded
                    self.selectedURL = requestedSelection.flatMap { requestedURL in
                        loaded.first { $0.url.standardizedFileURL == requestedURL.standardizedFileURL }?.url
                    } ?? self.filteredItems.first(where: { !$0.isDirectory })?.url
                        ?? self.filteredItems.first?.url
                    self.isLoading = false
                    if presentingViewer {
                        self.isViewerPresented = self.selectedURL != nil
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.loadToken == token else { return }
                    self.items = []
                    self.selectedURL = nil
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    /// Opens a Finder-selected image in context, so returning from the viewer
    /// reveals every image in the same directory.
    func openImageInContainingFolder(_ url: URL) {
        loadFolder(
            url.deletingLastPathComponent(),
            selecting: url,
            presentingViewer: true
        )
    }

    private func reloadCurrentFolder() {
        guard let folderURL else { return }
        loadFolder(folderURL, recordingHistory: false)
    }

    func goBack() {
        guard canGoBack else { return }
        folderHistoryIndex -= 1
        loadFolder(folderHistory[folderHistoryIndex], recordingHistory: false)
    }

    func goForward() {
        guard canGoForward else { return }
        folderHistoryIndex += 1
        loadFolder(folderHistory[folderHistoryIndex], recordingHistory: false)
    }

    private func recordFolderVisit(_ url: URL) {
        let folder = url.standardizedFileURL
        if folderHistoryIndex >= 0,
           folderHistory[folderHistoryIndex].standardizedFileURL == folder {
            return
        }
        if folderHistoryIndex + 1 < folderHistory.count {
            folderHistory.removeSubrange((folderHistoryIndex + 1)..<folderHistory.count)
        }
        folderHistory.append(folder)
        folderHistoryIndex = folderHistory.count - 1
    }

    nonisolated private static func folderItems(
        in folder: URL,
        showsSubdirectories: Bool,
        supportedExtensions: Set<String>
    ) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        let entries = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        let folders = showsSubdirectories ? entries.filter { url in
            var directory = ObjCBool(false)
            FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            return directory.boolValue
        } : []
        let images = entries.filter { url in
            var directory = ObjCBool(false)
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            return exists && !directory.boolValue && supportedExtensions.contains(url.pathExtension.lowercased())
        }
        return folders + images
    }

    func loadImages(_ urls: [URL]) {
        folderURL = nil
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let loaded = urls.map(ImageItem.init)
            await MainActor.run {
                self.items = loaded
                self.selectedURL = loaded.first?.url
                self.isLoading = false
                self.isViewerPresented = true
            }
        }
    }

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    func open(_ item: ImageItem) {
        selectedURL = item.url
        if item.isDirectory {
            loadFolder(item.url)
        } else {
            isViewerPresented = true
        }
    }

    func openSelectedItem() {
        guard let selectedItem else { return }
        open(selectedItem)
    }

    func select(_ item: ImageItem) {
        selectedURL = item.url
    }

    /// Arrow-key navigation follows the current presentation: list and viewer
    /// use a linear sequence, while the thumbnail grid follows visible cells.
    func navigate(_ direction: ImageNavigationDirection) {
        if isViewerPresented || viewMode == .list {
            switch direction {
            case .left, .up: selectPrevious()
            case .right, .down: selectNext()
            }
            return
        }

        moveThumbnailSelection(direction)
    }

    func setThumbnailColumnCount(_ count: Int) {
        thumbnailColumnCount = max(1, count)
    }

    /// Moves the active image to the macOS Trash, then keeps the viewer on the
    /// next image, skipping folders. If no later image remains, use the
    /// previous image; close the viewer only when no images remain.
    func moveSelectedItemToTrash() {
        guard let selectedURL,
              let currentIndex = filteredItems.firstIndex(where: { $0.url == selectedURL }) else {
            return
        }

        do {
            try FileManager.default.trashItem(at: selectedURL, resultingItemURL: nil)
            items.removeAll { $0.url == selectedURL }

            let remainingItems = filteredItems
            guard let nextImage = remainingItems.dropFirst(currentIndex).first(where: { !$0.isDirectory })
                ?? remainingItems.prefix(currentIndex).last(where: { !$0.isDirectory }) else {
                self.selectedURL = nil
                isViewerPresented = false
                return
            }
            self.selectedURL = nextImage.url
        } catch {
            errorMessage = "无法移到废纸篓：\(error.localizedDescription)"
        }
    }

    func sort(by sort: LibrarySort) {
        if self.sort == sort {
            ascending.toggle()
        } else {
            self.sort = sort
            ascending = true
        }
    }

    private func moveSelection(by offset: Int) {
        let visible = filteredItems.filter { !$0.isDirectory }
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.url == selectedURL } ?? 0
        selectedURL = visible[(current + offset + visible.count) % visible.count].url
    }

    private func moveThumbnailSelection(_ direction: ImageNavigationDirection) {
        let visible = filteredItems
        guard !visible.isEmpty else { return }

        let current = visible.firstIndex { $0.url == selectedURL } ?? 0
        let columns = thumbnailColumnCount
        let target: Int

        switch direction {
        case .left:
            target = current.isMultiple(of: columns) ? current : current - 1
        case .right:
            let isLastInRow = (current + 1).isMultiple(of: columns)
            target = isLastInRow || current + 1 == visible.count ? current : current + 1
        case .up:
            target = current >= columns ? current - columns : current
        case .down:
            target = current + columns < visible.count ? current + columns : current
        }

        selectedURL = visible[target].url
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    func image(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: url as NSURL, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}
