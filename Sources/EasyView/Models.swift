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

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }
    var dimensionsText: String { width > 0 ? "\(width) × \(height)" : "—" }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }

    init(url: URL) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        fileSize = Int64(values?.fileSize ?? 0)
        modifiedAt = values?.contentModificationDate

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
    @Published var recursivelyShowsSubdirectories: Bool = UserDefaults.standard.object(forKey: "recursivelyShowsSubdirectories") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(recursivelyShowsSubdirectories, forKey: "recursivelyShowsSubdirectories")
            reloadCurrentFolder()
        }
    }

    private let supportedExtensions = Set(["jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp"])
    private var loadToken = UUID()

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
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .type:
                return lhs.fileExtension.localizedStandardCompare(rhs.fileExtension) == .orderedAscending
            case .date:
                return (lhs.modifiedAt ?? .distantPast) < (rhs.modifiedAt ?? .distantPast)
            case .size:
                return lhs.fileSize < rhs.fileSize
            case .dimensions:
                return lhs.width * lhs.height < rhs.width * rhs.height
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
        presentingViewer: Bool = false
    ) {
        folderURL = url
        isLoading = true
        errorMessage = nil
        let extensions = supportedExtensions
        let recursively = recursivelyShowsSubdirectories
        let token = UUID()
        loadToken = token
        Task.detached(priority: .userInitiated) {
            do {
                let urls = try Self.imageURLs(
                    in: url,
                    recursively: recursively,
                    supportedExtensions: extensions
                )
                let loaded = urls.map(ImageItem.init)
                await MainActor.run {
                    guard self.loadToken == token else { return }
                    self.items = loaded
                    self.selectedURL = requestedSelection.flatMap { requestedURL in
                        loaded.first { $0.url.standardizedFileURL == requestedURL.standardizedFileURL }?.url
                    } ?? loaded.first?.url
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
        loadFolder(folderURL)
    }

    nonisolated private static func imageURLs(
        in folder: URL,
        recursively: Bool,
        supportedExtensions: Set<String>
    ) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        if !recursively {
            return try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            ).filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        }

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        return enumerator.compactMap { $0 as? URL }.filter { url in
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
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

    /// Moves the active image to the macOS Trash, then keeps the viewer on the
    /// following image (or the previous one when the deleted image was last).
    func moveSelectedItemToTrash() {
        guard let selectedURL,
              let currentIndex = filteredItems.firstIndex(where: { $0.url == selectedURL }) else {
            return
        }

        do {
            try FileManager.default.trashItem(at: selectedURL, resultingItemURL: nil)
            items.removeAll { $0.url == selectedURL }

            let remainingItems = filteredItems
            guard !remainingItems.isEmpty else {
                self.selectedURL = nil
                isViewerPresented = false
                return
            }
            self.selectedURL = remainingItems[min(currentIndex, remainingItems.count - 1)].url
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
        let visible = filteredItems
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.url == selectedURL } ?? 0
        selectedURL = visible[(current + offset + visible.count) % visible.count].url
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
