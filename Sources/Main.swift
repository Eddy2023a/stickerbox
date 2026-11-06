import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import ApplicationServices

struct XY: Codable { let x: Double; let y: Double }
struct TextBox: Codable { let topLeft: XY; let bottomRight: XY }
struct RGBA: Codable {
    let red: Double; let green: Double; let blue: Double; let alpha: Double
    var color: NSColor { NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha / 255) }
}
struct Composition: Codable { let bBox: TextBox; let textColor: RGBA; let shadowColor: RGBA }
struct Sticker: Codable {
    let id: String
    let md5: String
    let width: Int
    let height: Int
    let url: String
    let thumbnailUrl: String
    let composition: Composition?
    static func bundled() -> [Sticker] {
        guard let file = Bundle.main.url(forResource: "templates", withExtension: "json"), let data = try? Data(contentsOf: file), let values = try? JSONDecoder().decode([Sticker].self, from: data) else { return [] }
        return values.compactMap { value in
            guard let resource = Bundle.main.resourceURL?.appendingPathComponent(value.url), FileManager.default.fileExists(atPath: resource.path) else { return nil }
            return Sticker(id: value.id, md5: value.md5, width: value.width, height: value.height, url: resource.absoluteString, thumbnailUrl: resource.absoluteString, composition: value.composition)
        }
    }
}
struct SearchResult: Codable {
    let ok: Bool
    let query: String
    let count: Int
    let hasNext: Bool
    let items: [Sticker]
    let templates: [Sticker]?
}
struct Connection: Codable { let version: Int; let baseUrl: String; let token: String; let expiresAt: Double? }
struct ErrorPayload: Decodable { let error: String? }

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class QQClient {
    private var connection: Connection?
    private let queue = DispatchQueue(label: "stickerbox.connection", qos: .userInitiated)
    private let session: URLSession
    private var searchTask: URLSessionDataTask?
    private var requestGeneration = 0
    private var connecting = false
    private var waiters: [(Result<Connection, Error>) -> Void] = []
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    func cancel() { requestGeneration += 1; searchTask?.cancel(); searchTask = nil }
    func reconnect() {
        connection = nil
    }
    func ensure(_ completion: @escaping (Result<Connection, Error>) -> Void) {
        if let current = connection { completion(.success(current)); return }
        waiters.append(completion)
        if connecting { return }
        connecting = true
        queue.async {
            do {
                guard let helper = Bundle.main.url(forResource: "connect_qq", withExtension: "py") else { throw AppError.message("连接组件缺失，请重新打开 App。") }
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [helper.path]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let text = (try? JSONDecoder().decode(ErrorPayload.self, from: data).error) ?? "QQ 未连接，请打开调试副本并登录。"
                    throw AppError.message(text)
                }
                let config = try JSONDecoder().decode(Connection.self, from: data)
                guard let url = URL(string: config.baseUrl), url.host == "127.0.0.1", url.scheme == "http" else { throw AppError.message("QQ 连接地址无效。") }
                DispatchQueue.main.async { self.finishConnection(.success(config)) }
            } catch { DispatchQueue.main.async { self.finishConnection(.failure(error)) } }
        }
    }
    private func finishConnection(_ result: Result<Connection, Error>) {
        connecting = false
        if case .success(let config) = result { connection = config }
        let callbacks = waiters; waiters.removeAll()
        callbacks.forEach { $0(result) }
    }
    func search(_ query: String, completion: @escaping (Result<SearchResult, Error>) -> Void) {
        cancel()
        let ticket = requestGeneration
        ensure { result in
            guard ticket == self.requestGeneration else { return }
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let config):
                var components = URLComponents(string: config.baseUrl + "/search")!
                components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "50")]
                var request = URLRequest(url: components.url!)
                request.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization")
                self.searchTask = self.session.dataTask(with: request) { data, response, error in
                    if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
                    var result: Result<SearchResult, Error>
                    do {
                        if let error = error { throw error }
                        guard let data = data, let response = response as? HTTPURLResponse else { throw AppError.message("QQ 暂时没有响应。") }
                        guard response.statusCode == 200 else {
                            let details = try? JSONDecoder().decode(ErrorPayload.self, from: data)
                            let raw = details?.error ?? "搜索暂时不可用，请重试。"
                            let message = raw.contains("already running") ? "正在处理上一次搜索，请稍候重试。" : raw.contains("timed out") ? "QQ 搜索超时，请再试一次。" : raw
                            throw AppError.message(message)
                        }
                        result = .success(try JSONDecoder().decode(SearchResult.self, from: data))
                    } catch { result = .failure(error) }
                    DispatchQueue.main.async { completion(result) }
                }
                self.searchTask?.resume()
            }
        }
    }
}

enum Render {
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static var cache: URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("StickerBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func thumbnail(_ data: Data, pixels: Int = 144) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    static func composed(_ image: CGImage, text: String, info: Composition) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let box = info.bBox
        let rect = CGRect(x: Double(width) * box.topLeft.x, y: Double(height) * (1 - box.bottomRight.y), width: Double(width) * (box.bottomRight.x - box.topLeft.x), height: Double(height) * (box.bottomRight.y - box.topLeft.y)).insetBy(dx: 1, dy: 1)
        guard rect.width > 0, rect.height > 0 else { return context.makeImage() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        var fontSize = min(CGFloat(height) * 0.15, rect.height * 0.88)
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measured = NSRect.zero
        repeat {
            attributes = [.font: NSFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: info.textColor.color, .strokeColor: info.shadowColor.color, .strokeWidth: -3.2, .paragraphStyle: paragraph]
            measured = (text as NSString).boundingRect(with: NSSize(width: rect.width, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
            if measured.height <= rect.height + 1 && measured.width <= rect.width + 1 { break }
            fontSize -= 1
        } while fontSize > max(7, CGFloat(height) * 0.035)
        let drawRect = NSRect(x: rect.minX, y: rect.midY - min(measured.height, rect.height) / 2, width: rect.width, height: min(measured.height, rect.height))
        (text as NSString).draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
    static func save(_ data: Data, sticker: Sticker, text: String?) throws -> URL {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw AppError.message("这张表情暂时无法读取。") }
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let count = CGImageSourceGetCount(source)
        let key = hash(sticker.md5 + "|" + (text ?? "original"))
        if let text = text, let composition = sticker.composition {
            let animated = count > 1
            let destination = cache.appendingPathComponent(key + (animated ? ".gif" : ".png"))
            if FileManager.default.fileExists(atPath: destination.path) { return destination }
            let outputType = animated ? UTType.gif.identifier : UTType.png.identifier
            guard let output = CGImageDestinationCreateWithURL(destination as CFURL, outputType as CFString, animated ? count : 1, nil) else { throw AppError.message("无法保存合成表情。") }
            if animated {
                let sourceProperties = CGImageSourceCopyProperties(source, nil) as? [String: Any]
                let gif = sourceProperties?[kCGImagePropertyGIFDictionary as String] ?? [kCGImagePropertyGIFLoopCount: 0]
                CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
            }
            for index in 0..<(animated ? count : 1) {
                autoreleasepool {
                    if let frame = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary), let result = composed(frame, text: text, info: composition) {
                        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                        CGImageDestinationAddImage(output, result, properties)
                    }
                }
            }
            guard CGImageDestinationFinalize(output) else { try? FileManager.default.removeItem(at: destination); throw AppError.message("合成失败，请换一个模板。") }
            return destination
        }
        let ext = type?.preferredFilenameExtension ?? "gif"
        let file = cache.appendingPathComponent(key + "." + ext)
        if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
        return file
    }
    static func copy(_ file: URL) throws -> Bool {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary) else { throw AppError.message("无法复制图片。") }
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        let animated = CGImageSourceGetCount(source) > 1
        if let type = CGImageSourceGetType(source) { item.setData(data, forType: NSPasteboard.PasteboardType(type as String)) }
        let png = NSMutableData()
        if let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { item.setData(png as Data, forType: .png) }
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([item]) else { throw AppError.message("剪贴板写入失败。") }
        return animated
    }
    static func trimDiskCache() {
        let protected = NSPasteboard.general.string(forType: .fileURL).flatMap { URL(string: $0)?.path }
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let ordered = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var total = 0
        for file in ordered {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
            if total > 80 * 1024 * 1024 && file.path != protected { try? FileManager.default.removeItem(at: file) }
        }
    }
}

final class ImageLoader {
    let cache = NSCache<NSString, NSImage>()
    private let session: URLSession
    private let lock = NSLock()
    private var tasks: [UUID: URLSessionDataTask] = [:]
    private var generation = 0
    init() {
        cache.totalCostLimit = 4 * 1024 * 1024
        cache.countLimit = 32
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }
    deinit { session.invalidateAndCancel() }
    func load(_ sticker: Sticker, text: String?, completion: @escaping (NSImage?) -> Void) {
        lock.lock(); let ticket = generation; lock.unlock()
        let key = (sticker.md5 + "|" + (text ?? "")) as NSString
        if let image = cache.object(forKey: key) { completion(image); return }
        guard let url = URL(string: sticker.thumbnailUrl.isEmpty ? sticker.url : sticker.thumbnailUrl) else { completion(nil); return }
        if url.isFileURL {
            DispatchQueue.global(qos: .userInitiated).async {
                var image: NSImage?
                if let data = try? Data(contentsOf: url), var cg = Render.thumbnail(data) {
                    if let text = text, let composition = sticker.composition, let rendered = Render.composed(cg, text: text, info: composition) { cg = rendered }
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
                    self.lock.lock()
                    if ticket == self.generation { self.cache.setObject(image!, forKey: key, cost: cg.width * cg.height * 4) }
                    self.lock.unlock()
                }
                DispatchQueue.main.async { completion(image) }
            }
            return
        }
        let id = UUID()
        let task = session.dataTask(with: url) { data, response, error in
            self.lock.lock(); self.tasks.removeValue(forKey: id); self.lock.unlock()
            guard error == nil, let data = data, data.count < 10 * 1024 * 1024, (response as? HTTPURLResponse)?.statusCode == 200 else { DispatchQueue.main.async { completion(nil) }; return }
            var cg = Render.thumbnail(data)
            if let text = text, let composition = sticker.composition, let original = cg { cg = Render.composed(original, text: text, info: composition) }
            guard let image = cg else { DispatchQueue.main.async { completion(nil) }; return }
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
            self.lock.lock()
            if ticket == self.generation { self.cache.setObject(nsImage, forKey: key, cost: image.width * image.height * 4) }
            self.lock.unlock()
            DispatchQueue.main.async { completion(nsImage) }
        }
        lock.lock(); tasks[id] = task; lock.unlock(); task.resume()
    }
    func clear() {
        lock.lock(); generation += 1; let active = Array(tasks.values); tasks.removeAll(); cache.removeAllObjects(); lock.unlock()
        active.forEach { $0.cancel() }
    }
}

final class CardButton: NSButton {
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}

final class StickerItem: NSCollectionViewItem {
    let button = CardButton()
    var key = ""
    var action: (() -> Void)?
    override func loadView() {
        view = NSView()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.wantsLayer = true; button.layer?.cornerRadius = 9
        button.target = self; button.action = #selector(clicked)
        view.addSubview(button)
        NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2), button.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2), button.topAnchor.constraint(equalTo: view.topAnchor, constant: 2), button.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2)])
    }
    override func prepareForReuse() { super.prepareForReuse(); key = ""; button.image = nil; action = nil }
    @objc func clicked() { action?() }
}

final class PanelController: NSViewController, NSSearchFieldDelegate, NSCollectionViewDataSource {
    let searchField = NSSearchField()
    private let collection = NSCollectionView()
    private let scroll = NSScrollView()
    private let allButton = NSButton(title: "全部表情", target: nil, action: nil)
    private let composeButton = NSButton(title: "生成表情", target: nil, action: nil)
    private let allLine = NSView(), composeLine = NSView()
    private let status = NSTextField(labelWithString: "点击菜单栏图标，读取剪贴板关键词")
    private let spinner = NSProgressIndicator()
    private let emptyTitle = NSTextField(labelWithString: "搜一个表情吧")
    private let emptyDetail = NSTextField(labelWithString: "输入关键词，或复制文字后点击菜单栏图标")
    private let client = QQClient(), images = ImageLoader()
    private var debounce: DispatchWorkItem?
    private var result: SearchResult?
    private var items: [Sticker] = []
    private var generation = 0
    private var tab = 0
    private var copying = false
    private var requestedQuery: String?
    private lazy var bundledTemplates = Sticker.bundled()
    var didCopy: ((Int) -> Void)?
    var inputText: String { searchField.currentEditor()?.string ?? searchField.stringValue }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 624, height: 560))
        view.wantsLayer = true
        searchField.placeholderString = "搜索表情"
        searchField.font = .systemFont(ofSize: 16)
        searchField.controlSize = .large
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.isBezeled = true
        searchField.drawsBackground = true
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.target = self; searchField.action = #selector(searchNow)
        searchField.setAccessibilityLabel("搜索表情")
        let reconnect = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重连 QQ")!, target: self, action: #selector(reconnectQQ))
        reconnect.isBordered = false; reconnect.toolTip = "重新连接 QQ"
        allButton.target = self; allButton.action = #selector(showAll)
        composeButton.target = self; composeButton.action = #selector(showCompose)
        for button in [allButton, composeButton] { button.isBordered = false; button.font = .systemFont(ofSize: 17, weight: .semibold); button.alignment = .left }
        for line in [allLine, composeLine] { line.wantsLayer = true; line.layer?.cornerRadius = 1.5; line.layer?.backgroundColor = NSColor.controlAccentColor.cgColor }
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 84, height: 94)
        layout.minimumInteritemSpacing = 10; layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 16, bottom: 14, right: 16)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.backgroundColors = [.clear]
        collection.frame = NSRect(x: 0, y: 0, width: 624, height: 420)
        collection.autoresizingMask = [.width]
        collection.register(StickerItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("Sticker"))
        collection.isSelectable = false
        scroll.documentView = collection
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        emptyTitle.font = .systemFont(ofSize: 21, weight: .semibold); emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center
        emptyDetail.font = .systemFont(ofSize: 12); emptyDetail.textColor = .tertiaryLabelColor; emptyDetail.alignment = .center
        for child in [searchField, reconnect, allButton, composeButton, allLine, composeLine, scroll, status, spinner, emptyTitle, emptyDetail] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 17), searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), searchField.trailingAnchor.constraint(equalTo: reconnect.leadingAnchor, constant: -10), searchField.heightAnchor.constraint(equalToConstant: 38),
            reconnect.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18), reconnect.centerYAnchor.constraint(equalTo: searchField.centerYAnchor), reconnect.widthAnchor.constraint(equalToConstant: 25), reconnect.heightAnchor.constraint(equalToConstant: 28),
            allButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22), allButton.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 15), allButton.heightAnchor.constraint(equalToConstant: 30), allButton.widthAnchor.constraint(equalToConstant: 86),
            composeButton.leadingAnchor.constraint(equalTo: allButton.trailingAnchor, constant: 28), composeButton.topAnchor.constraint(equalTo: allButton.topAnchor), composeButton.heightAnchor.constraint(equalTo: allButton.heightAnchor), composeButton.widthAnchor.constraint(equalToConstant: 100),
            allLine.leadingAnchor.constraint(equalTo: allButton.leadingAnchor), allLine.topAnchor.constraint(equalTo: allButton.bottomAnchor, constant: 2), allLine.heightAnchor.constraint(equalToConstant: 3), allLine.widthAnchor.constraint(equalToConstant: 70),
            composeLine.leadingAnchor.constraint(equalTo: composeButton.leadingAnchor), composeLine.topAnchor.constraint(equalTo: allLine.topAnchor), composeLine.heightAnchor.constraint(equalTo: allLine.heightAnchor), composeLine.widthAnchor.constraint(equalToConstant: 70),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: allLine.bottomAnchor, constant: 12), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22), status.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -10), status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -13), status.heightAnchor.constraint(equalToConstant: 17),
            spinner.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22), spinner.centerYAnchor.constraint(equalTo: status.centerYAnchor), spinner.widthAnchor.constraint(equalToConstant: 16), spinner.heightAnchor.constraint(equalToConstant: 16),
            emptyTitle.centerXAnchor.constraint(equalTo: view.centerXAnchor), emptyTitle.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -16),
            emptyDetail.centerXAnchor.constraint(equalTo: view.centerXAnchor), emptyDetail.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 9)
        ])
        updateTab()
    }
    func open() {
        _ = view
        if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 100 {
            if inputText != text { searchField.stringValue = text; searchField.currentEditor()?.string = text; performSearch(); return }
        }
        if result != nil { updateItems() }
        else if !searchField.stringValue.isEmpty { performSearch() }
    }
    func closed() {
        generation += 1; debounce?.cancel(); debounce = nil; client.cancel(); images.clear(); result = nil
        requestedQuery = nil
        for item in collection.visibleItems() { (item as? StickerItem)?.button.image = nil }
        items = []; collection.reloadData()
        spinner.stopAnimation(nil)
    }
    func focusSearch() { view.window?.makeFirstResponder(searchField) }
    func loadQuery(_ query: String) { _ = view; searchField.stringValue = query; performSearch() }
    func controlTextDidChange(_ obj: Notification) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performSearch() }
        debounce = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { searchNow(); return true }
        return false
    }
    @objc private func searchNow() { debounce?.cancel(); performSearch() }
    @objc private func reconnectQQ() { client.reconnect(); requestedQuery = nil; performSearch() }
    @objc private func showAll() {
        tab = 0; updateTab()
        if result?.query == inputText.trimmingCharacters(in: .whitespacesAndNewlines) { updateItems() }
        else { performSearch() }
    }
    @objc private func showCompose() { tab = 1; requestedQuery = nil; generation += 1; debounce?.cancel(); client.cancel(); spinner.stopAnimation(nil); updateTab(); updateItems() }
    private func updateTab() {
        allButton.contentTintColor = tab == 0 ? .labelColor : .secondaryLabelColor
        composeButton.contentTintColor = tab == 1 ? .labelColor : .secondaryLabelColor
        allLine.isHidden = tab != 0; composeLine.isHidden = tab != 1
    }
    private func performSearch(retryConnection: Bool = true) {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if requestedQuery == query && tab == 0 { return }
        requestedQuery = nil
        generation += 1; let ticket = generation
        images.clear(); client.cancel()
        guard !query.isEmpty else {
            result = nil; items = []; collection.reloadData(); spinner.stopAnimation(nil)
            emptyTitle.stringValue = "搜一个表情吧"; emptyDetail.stringValue = "输入关键词，或复制文字后点击菜单栏图标"
            emptyTitle.isHidden = false; emptyDetail.isHidden = false; status.stringValue = "点击菜单栏图标，读取剪贴板关键词"; return
        }
        guard query.count <= 100 else { status.stringValue = "关键词最多 100 个字符"; return }
        if tab == 1 { spinner.stopAnimation(nil); updateItems(); return }
        requestedQuery = query
        status.stringValue = "正在搜索…"; spinner.startAnimation(nil)
        emptyTitle.isHidden = true; emptyDetail.isHidden = true
        client.search(query) { [weak self] response in
            guard let self = self, self.generation == ticket else { return }
            self.requestedQuery = nil
            self.spinner.stopAnimation(nil)
            switch response {
            case .success(let value): self.result = value; self.updateItems()
            case .failure(let error):
                if retryConnection {
                    self.client.reconnect()
                    self.performSearch(retryConnection: false)
                    return
                }
                self.items = []; self.collection.reloadData()
                self.emptyTitle.stringValue = "搜索暂时不可用"
                self.emptyDetail.stringValue = "稍后重试，或确认 QQ 已登录后点右上角重连"
                self.emptyTitle.isHidden = false; self.emptyDetail.isHidden = false
                self.status.stringValue = error.localizedDescription
                self.client.reconnect()
            }
        }
    }
    private func updateItems() {
        images.clear()
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab == 0 { items = result?.items ?? [] }
        else {
            let remote = result?.query == query ? (result?.templates ?? []) : []
            let identifiers = Set(remote.map { $0.md5 })
            items = remote + bundledTemplates.filter { !identifiers.contains($0.md5) }
        }
        collection.reloadData()
        scroll.contentView.scroll(to: .zero)
        emptyTitle.isHidden = !items.isEmpty; emptyDetail.isHidden = !items.isEmpty
        if items.isEmpty {
            emptyTitle.stringValue = tab == 0 ? "没有找到表情" : "这句话暂时没有合成模板"
            emptyDetail.stringValue = tab == 0 ? "换个关键词试试" : "试试更短的文字，比如“开心”或“娃哈哈”"
        }
        if tab == 1 { status.stringValue = "\(items.count) 个模板 · 本地合成，点击复制" }
        else if let result = result { status.stringValue = "“\(result.query)” · \(items.count) 个表情 · 点击复制原图" }
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("Sticker"), for: indexPath) as! StickerItem
        let sticker = items[indexPath.item]
        let text = tab == 1 ? inputText.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let key = sticker.md5 + "|" + (text ?? "")
        cell.key = key
        cell.button.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        cell.button.setAccessibilityLabel((tab == 0 ? "表情 " : "合成模板 ") + String(indexPath.item + 1))
        cell.button.toolTip = tab == 0 ? "点击复制原图（保留动图）" : "点击合成并复制"
        cell.action = { [weak self] in self?.copy(sticker, text: text) }
        images.load(sticker, text: text) { [weak cell] image in
            guard let cell = cell, cell.key == key else { return }
            if let image = image { cell.button.image = image }
        }
        return cell
    }
    private func copy(_ sticker: Sticker, text: String?) {
        guard !copying, let url = URL(string: sticker.url) else { return }
        if let text = text, text.isEmpty { status.stringValue = "先输入想放在表情上的文字"; return }
        let afterCopy = didCopy
        copying = true; spinner.startAnimation(nil); status.stringValue = text == nil ? "正在复制原图…" : "正在合成并复制…"
        let finish: (Data?, Error?) -> Void = { data, error in
            var outcome: Result<URL, Error>
            do {
                if let error = error { throw error }
                guard let data = data, data.count < 20 * 1024 * 1024 else { throw AppError.message("图片暂时无法下载，请重新搜索。") }
                outcome = .success(try Render.save(data, sticker: sticker, text: text))
            } catch { outcome = .failure(error) }
            DispatchQueue.main.async {
                self.copying = false; self.spinner.stopAnimation(nil)
                do {
                    let file = try outcome.get()
                    let animated = try Render.copy(file)
                    self.status.stringValue = animated ? "已复制动图，可直接粘贴" : "已复制图片，可直接粘贴"
                    DispatchQueue.global(qos: .utility).async { Render.trimDiskCache() }
                    let clipboardVersion = NSPasteboard.general.changeCount
                    afterCopy?(clipboardVersion)
                } catch { self.status.stringValue = error.localizedDescription }
            }
        }
        if url.isFileURL {
            DispatchQueue.global(qos: .userInitiated).async {
                do { finish(try Data(contentsOf: url), nil) } catch { finish(nil, error) }
            }
        } else {
            URLSession.shared.dataTask(with: url) { data, response, error in
                if let error = error { finish(nil, error) }
                else if (response as? HTTPURLResponse)?.statusCode == 200 { finish(data, nil) }
                else { finish(nil, AppError.message("图片暂时无法下载，请重新搜索。")) }
            }.resume()
        }
    }
}

final class FeishuContextMenu: NSObject {
    var search: ((String, NSPoint) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var permissionObserver: NSObjectProtocol?
    private var suppressUp = false
    private var menuOpen = false
    private var target: NSRunningApplication?
    private var point = NSPoint.zero
    private var click = CGPoint.zero
    private let replayTag: Int64 = 0x53544258
    var isRunning: Bool { tap != nil }
    var sourceApplication: NSRunningApplication? { target }

    func start() {
        install()
        guard tap == nil else { return }
        permissionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.install() }
    }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        install()
    }
    private func install() {
        guard tap == nil else { return }
        let trusted = AXIsProcessTrusted()
        try? "accessibility=\(trusted)\n".write(toFile: NSTemporaryDirectory() + "stickerbox-menu-status.txt", atomically: true, encoding: .utf8)
        guard trusted else { return }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context = context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<FeishuContextMenu>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.suppressUp = false
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.eventSourceUserData) == owner.replayTag { return Unmanaged.passUnretained(event) }
            if type == .rightMouseUp, owner.suppressUp { owner.suppressUp = false; return nil }
            guard type == .rightMouseDown, !owner.menuOpen,
                  let app = NSWorkspace.shared.frontmostApplication,
                  ["com.electron.lark", "com.electron.feishu"].contains(app.bundleIdentifier ?? "") else {
                return Unmanaged.passUnretained(event)
            }
            owner.suppressUp = true
            owner.target = app; owner.click = event.location
            owner.point = NSPoint(x: event.location.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - event.location.y)
            DispatchQueue.main.async { owner.showMenu() }
            return nil
        }
        let mask = CGEventMask((1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.rightMouseUp.rawValue))
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        try? "accessibility=true eventTap=\(tap != nil)\n".write(toFile: NSTemporaryDirectory() + "stickerbox-menu-status.txt", atomically: true, encoding: .utf8)
        if let tap = tap {
            if let observer = permissionObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(observer); permissionObserver = nil
            }
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    private func showMenu() {
        guard !menuOpen else { return }
        menuOpen = true
        let menu = NSMenu()
        for (title, action) in [("复制", #selector(copyText)), ("剪切", #selector(cutText)), ("粘贴", #selector(pasteText))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        menu.addItem(.separator())
        let searchItem = menu.addItem(withTitle: "表情搜索", action: #selector(searchText), keyEquivalent: "")
        searchItem.target = self
        menu.addItem(.separator())
        let original = menu.addItem(withTitle: "飞书原右键菜单", action: #selector(originalMenu), keyEquivalent: "")
        original.target = self
        menu.popUp(positioning: nil, at: point, in: nil)
        menuOpen = false
    }
    private func sendCommand(_ key: CGKeyCode, completion: (() -> Void)? = nil) {
        guard let app = target, !app.isTerminated else { return }
        app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
                event?.flags = .maskCommand
                event?.postToPid(app.processIdentifier)
            }
            completion?()
        }
    }
    @objc private func copyText() { sendCommand(8) }
    @objc private func cutText() { sendCommand(7) }
    @objc private func pasteText() { sendCommand(9) }
    @objc private func originalMenu() {
        let location = click
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for type in [CGEventType.rightMouseDown, .rightMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .right)
                event?.setIntegerValueField(.eventSourceUserData, value: self.replayTag)
                event?.post(tap: .cghidEventTap)
            }
        }
    }
    @objc private func searchText() {
        let board = NSPasteboard.general
        // Snapshot every advertised format before using Copy to read Electron's selection.
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let snapshot = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { snapshot.setData(data, forType: type) } }
            return snapshot
        }
        let before = board.changeCount
        let anchor = point
        sendCommand(8) { self.waitForCopy(previous: before, saved: saved, anchor: anchor, attempts: 16) }
    }
    private func waitForCopy(previous: Int, saved: [NSPasteboardItem], anchor: NSPoint, attempts: Int) {
        let board = NSPasteboard.general
        if board.changeCount != previous {
            let copiedVersion = board.changeCount
            let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if board.changeCount == copiedVersion {
                board.clearContents()
                if !saved.isEmpty { board.writeObjects(saved) }
            }
            // Empty / oversized selections open an editable search field without sending a query.
            search?(text.count <= 100 ? text : "", anchor)
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.waitForCopy(previous: previous, saved: saved, anchor: anchor, attempts: attempts - 1)
            }
        } else { search?("", anchor) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var panel: PanelController?
    private var previewWindow: NSWindow?
    private var selectionWindow: NSPanel?
    private var selectionController: PanelController?
    private var outsideClickMonitor: Any?
    private let feishuMenu = FeishuContextMenu()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        feishuMenu.search = { [weak self] text, point in
            guard let self = self else { return }
            self.showSelection(text, at: point, source: self.feishuMenu.sourceApplication)
        }
        feishuMenu.start()
        if CommandLine.arguments.contains("--enable-feishu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.feishuMenu.requestPermission() }
        }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "表情匣")
            button.toolTip = "表情匣：读取剪贴板并搜索表情"
            button.target = self; button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("表情匣")
        }
        if CommandLine.arguments.contains("--preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let controller = PanelController()
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 624, height: 560), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
                window.title = "表情匣"
                window.contentViewController = controller
                let accessory = NSTitlebarAccessoryViewController()
                accessory.layoutAttribute = .right
                let testButton = NSButton(title: "菜单弹窗", target: self, action: #selector(self.previewClipboard))
                testButton.frame = NSRect(x: 0, y: 0, width: 88, height: 26)
                accessory.view = testButton
                window.addTitlebarAccessoryViewController(accessory)
                window.center(); window.makeKeyAndOrderFront(nil)
                self.previewWindow = window
                NSApp.activate(ignoringOtherApps: true)
                controller.loadQuery("娃哈哈")
            }
        } else if CommandLine.arguments.contains("--show") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.show() } }
    }
    @objc private func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开表情匣", action: #selector(showMenu), keyEquivalent: "")
            menu.addItem(withTitle: "打开 QQ 调试副本", action: #selector(openQQ), keyEquivalent: "")
            menu.addItem(withTitle: feishuMenu.isRunning ? "飞书右键菜单已启用" : "启用飞书右键菜单…", action: #selector(enableFeishuMenu), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "退出表情匣", action: #selector(quit), keyEquivalent: "q")
            menu.items.forEach { $0.target = self }
            statusItem.popUpMenu(menu)
        } else if popover?.isShown == true { popover?.performClose(nil) }
        else { show() }
    }
    @objc private func enableFeishuMenu() { feishuMenu.requestPermission() }
    @objc private func showMenu() { show() }
    @objc private func previewClipboard() {
        if let controller = previewWindow?.contentViewController as? PanelController {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(controller.inputText, forType: .string)
        }
        show()
    }
    @objc private func openQQ() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/StickerBox/QQ-debug.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
    @objc func searchEmoji(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let raw = pasteboard.string(forType: .string) else {
            error.pointee = "请先选中文字。"; return
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 100 else {
            error.pointee = "请选择 1 到 100 字的搜索关键词。"; return
        }
        let point = NSEvent.mouseLocation
        let source = NSWorkspace.shared.frontmostApplication
        DispatchQueue.main.async { [weak self] in self?.showSelection(text, at: point, source: source) }
    }
    private func finishCopy(to source: NSRunningApplication?, clipboardVersion: Int) {
        let front = NSWorkspace.shared.frontmostApplication
        let mayReturn = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier || front?.processIdentifier == source?.processIdentifier
        closeSelection(); popover?.performClose(nil)
        NSApp.hide(nil)
        guard mayReturn, AXIsProcessTrusted(), let source = source, !source.isTerminated,
              ["com.electron.lark", "com.electron.feishu"].contains(source.bundleIdentifier ?? "") else { return }
        source.activate(options: [.activateIgnoringOtherApps])
        // Wait for the original editor to regain focus, then paste once. Never send Return.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == source.processIdentifier,
                  NSPasteboard.general.changeCount == clipboardVersion else { return }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down)
                event?.flags = .maskCommand
                event?.postToPid(source.processIdentifier)
            }
        }
    }
    private func closeSelection() {
        selectionWindow?.delegate = nil
        selectionWindow?.orderOut(nil)
        selectionController?.closed()
        selectionWindow?.contentViewController = nil
        selectionController = nil; selectionWindow = nil
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor); outsideClickMonitor = nil }
    }
    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === selectionWindow { closeSelection() }
    }
    private func showSelection(_ text: String, at point: NSPoint, source: NSRunningApplication?) {
        popover?.performClose(nil)
        if selectionWindow == nil {
            let controller = PanelController()
            controller.didCopy = { [weak self] version in self?.finishCopy(to: source, clipboardVersion: version) }
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 624, height: 560),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "表情匣"; window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true; window.isMovableByWindowBackground = true
            window.level = .popUpMenu; window.delegate = self
            window.contentViewController = controller
            selectionWindow = window; selectionController = controller
        }
        guard let window = selectionWindow else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let bounds = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 8, dy: 8)
        let size = window.frame.size
        let x = min(max(point.x + 8, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        let y = min(max(point.y - size.height - 8, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        window.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        selectionController?.loadQuery(text); selectionController?.focusSearch()
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.closeSelection() }
        }
    }
    private func show() {
        let source = NSWorkspace.shared.frontmostApplication
        closeSelection()
        guard let button = statusItem.button else { return }
        if panel == nil {
            let controller = PanelController(); controller.didCopy = { [weak self] version in
                self?.finishCopy(to: source, clipboardVersion: version)
                self?.statusItem.button?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已复制")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.statusItem.button?.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "表情匣") }
            }
            let popup = NSPopover(); popup.behavior = .transient; popup.animates = false; popup.delegate = self; popup.contentViewController = controller; popup.contentSize = NSSize(width: 624, height: 560)
            panel = controller; popover = popup
        }
        NSApp.activate(ignoringOtherApps: true)
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel?.open(); panel?.focusSearch()
        if CommandLine.arguments.contains("--preview") { fputs("POPOVER_VISIBLE \(popover?.isShown == true) STATUS_VISIBLE \(statusItem.isVisible)\n", stderr) }
    }
    func popoverDidClose(_ notification: Notification) {
        panel?.closed()
        popover?.contentViewController = nil
        panel = nil; popover = nil
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    @objc private func quit() { NSApp.terminate(nil) }
}

func selfTest() -> Int32 {
    do {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--self-test"), arguments.count > index + 2 else { return 2 }
        let input = URL(fileURLWithPath: arguments[index + 1]), output = URL(fileURLWithPath: arguments[index + 2])
        let info = Composition(bBox: TextBox(topLeft: XY(x: 0.05, y: 0.73), bottomRight: XY(x: 0.95, y: 0.98)), textColor: RGBA(red: 0, green: 0, blue: 0, alpha: 255), shadowColor: RGBA(red: 255, green: 255, blue: 255, alpha: 255))
        let sticker = Sticker(id: "self-test", md5: Render.hash(input.path), width: 240, height: 240, url: input.absoluteString, thumbnailUrl: input.absoluteString, composition: info)
        let result = try Render.save(Data(contentsOf: input), sticker: sticker, text: "娃哈哈")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: result, to: output)
        let animated = try Render.copy(result)
        print("COPY_OK animated=\(animated) types=\(NSPasteboard.general.types?.map { $0.rawValue } ?? [])")
        return 0
    } catch { fputs("\(error)\n", stderr); return 1 }
}

if CommandLine.arguments.contains("--self-test") { exit(selfTest()) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
