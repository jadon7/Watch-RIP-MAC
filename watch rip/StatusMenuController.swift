import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

class StatusMenuController: NSObject {
    private var statusItem: NSStatusItem!
    private var ipCheckTimer: Timer?
    private var cropperWindow: NSWindow?
    private var currentUploadedFile: String = "暂无文件"
    
    override init() {
        super.init()
        setupStatusItem()
        startIPCheck()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            // 从 Assets.xcassets 加载自定义图标
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true  // 设置为模板图片，这样系统会自动处理明暗模式
                button.image = image
            }
        }
        
        let menu = NSMenu()
        
        // IP 地址显示项（分两行）
        let titleItem = NSMenuItem(title: "上传文件后手表端输入:", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        let ipItem = NSMenuItem(title: "获取IP中...", action: nil, keyEquivalent: "")
        ipItem.attributedTitle = NSAttributedString(
            string: "获取IP中...",
            attributes: [
                .foregroundColor: NSColor.black,
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )
        menu.addItem(ipItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 当前文件显示项
        let fileItem = NSMenuItem(title: "当前文件：暂无文件", action: nil, keyEquivalent: "")
        fileItem.isEnabled = false
        menu.addItem(fileItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 图片/视频上传选项
        let mediaItem = NSMenuItem(title: "上传图片/视频", action: #selector(openMediaPicker), keyEquivalent: "")
        mediaItem.target = self
        menu.addItem(mediaItem)
        
        // Rive 文件上传选项
        let riveItem = NSMenuItem(title: "上传 Rive 文件", action: #selector(openRivePicker), keyEquivalent: "")
        riveItem.target = self
        menu.addItem(riveItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 退出选项
        let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    private func startIPCheck() {
        updateIPAddress()
        ipCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateIPAddress()
        }
    }
    
    private func updateIPAddress() {
        if let ip = UploadServer.shared.getLocalIPAddress() {
            if let menu = statusItem.menu {
                // 去掉端口号
                let components = ip.split(separator: ":")
                if let ipWithoutPort = components.first.map(String.init) {
                    menu.item(at: 1)?.attributedTitle = NSAttributedString(
                        string: ipWithoutPort,
                        attributes: [
                            .foregroundColor: NSColor.black.withAlphaComponent(0.9),
                            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
                        ]
                    )
                }
            }
        }
    }
    
    private func updateCurrentFile(_ filename: String) {
        currentUploadedFile = filename
        if let menu = statusItem.menu {
            menu.item(at: 3)?.title = "当前文件：\(filename)"
        }
    }
    
    @objc private func openMediaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.image, UTType.movie]
        
        // 激活应用程序
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        panel.begin { [weak self] result in
            if result == .OK {
                self?.handleMediaFiles(panel.urls)
            }
        }
    }
    
    @objc private func openRivePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        var allowedTypes: [UTType] = []
        if let t = UTType(filenameExtension: "riv") {
            allowedTypes.append(t)
        }
        if let t = UTType(filenameExtension: "rive") {
            allowedTypes.append(t)
        }
        panel.allowedContentTypes = allowedTypes.isEmpty ? [UTType.data] : allowedTypes
        
        // 激活应用程序
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        panel.begin { result in
            if result == .OK {
                self.handleRiveFile(panel.url)
            }
        }
    }
    
    private func handleMediaFiles(_ files: [URL]) {
        let uploadDir = UploadServer.shared.uploadDirectory
        let fm = FileManager.default
        
        // 清空上传目录中的所有文件
        if let existingFiles = try? fm.contentsOfDirectory(at: uploadDir, includingPropertiesForKeys: nil) {
            for file in existingFiles {
                // 删除所有现有文件，包括 rive 文件
                try? fm.removeItem(at: file)
            }
        }
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let tempDir = uploadDir.appendingPathComponent("temp_\(timestamp)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        processFiles(files, index: 0, tempDir: tempDir) {
            let zipURL = uploadDir.appendingPathComponent("media_\(timestamp).zip")
            try? fm.zipItem(at: tempDir, to: zipURL, shouldKeepParent: false)
            try? fm.removeItem(at: tempDir)
            self.updateCurrentFile("media_\(timestamp).zip")
            UploadServer.shared.notifyClients()
        }
    }
    
    private func handleRiveFile(_ fileURL: URL?) {
        guard let fileURL = fileURL else { return }
        
        let uploadDir = UploadServer.shared.uploadDirectory
        let fm = FileManager.default
        
        // 清空上传目录中的所有文件
        if let existingFiles = try? fm.contentsOfDirectory(at: uploadDir, includingPropertiesForKeys: nil) {
            for file in existingFiles {
                // 如果是临时目录或 zip 文件，删除它们
                if file.lastPathComponent.hasPrefix("temp_") || file.pathExtension == "zip" {
                    try? fm.removeItem(at: file)
                }
                // 如果是旧的 rive 文件，也删除它
                if file.pathExtension == "riv" || file.pathExtension == "rive" {
                    try? fm.removeItem(at: file)
                }
            }
        }
        
        let ext = fileURL.pathExtension
        let destURL = uploadDir.appendingPathComponent("rive.\(ext)")
        
        do {
            try fm.copyItem(at: fileURL, to: destURL)
            self.updateCurrentFile("rive.\(ext)")
            UploadServer.shared.notifyClients()
        } catch {
            print("文件上传失败: \(error.localizedDescription)")
        }
    }
    
    private func processFiles(_ files: [URL], index: Int, tempDir: URL, completion: @escaping () -> Void) {
        if index >= files.count {
            completion()
            return
        }
        
        let fileURL = files[index]
        let ext = fileURL.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "heic", "tiff", "bmp"]
        let fm = FileManager.default
        
        if imageExtensions.contains(ext) {
            if let image = NSImage(contentsOf: fileURL) {
                let width = image.size.width
                let height = image.size.height
                if abs(width - height) > 1 {
                    presentImageCropper(for: image) { cropped in
                        let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                        if let cropped = cropped,
                           let tiffData = cropped.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiffData),
                           let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: destURL)
                        } else {
                            try? fm.copyItem(at: fileURL, to: destURL)
                        }
                        self.processFiles(files, index: index + 1, tempDir: tempDir, completion: completion)
                    }
                    return
                } else {
                    let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
                    if let processed = processNonCroppedImage(image),
                       let tiffData = processed.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiffData),
                       let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: destURL)
                    }
                }
            }
        } else if ["mp4", "mov", "m4v", "avi", "flv"].contains(ext) {
            let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
            let asset = AVAsset(url: fileURL)
            if let videoTrack = asset.tracks(withMediaType: .video).first,
               videoTrack.naturalSize.width != videoTrack.naturalSize.height {
                presentVideoCropper(for: fileURL) { processedURL in
                    if let processedURL = processedURL {
                        try? fm.copyItem(at: processedURL, to: destURL)
                    } else {
                        try? fm.copyItem(at: fileURL, to: destURL)
                    }
                    self.processFiles(files, index: index + 1, tempDir: tempDir, completion: completion)
                }
                return
            } else {
                try? fm.copyItem(at: fileURL, to: destURL)
            }
        } else {
            let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
            try? fm.copyItem(at: fileURL, to: destURL)
        }
        
        processFiles(files, index: index + 1, tempDir: tempDir, completion: completion)
    }
    
    private func presentImageCropper(for image: NSImage, completion: @escaping (NSImage?) -> Void) {
        let cropperView = ImageCropperView(originalImage: image, onComplete: { croppedImage in
            self.cropperWindow?.close()
            self.cropperWindow = nil
            completion(croppedImage)
        }, onCancel: {
            self.cropperWindow?.close()
            self.cropperWindow = nil
            completion(nil)
        })
        
        let hostingController = NSHostingController(rootView: cropperView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "请裁切图片以保证1:1显示"
        window.setContentSize(NSSize(width: 420, height: 0))
        window.styleMask = [.titled, .closable]
        
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = window.frame
            let x = screenRect.midX - windowRect.width / 2
            let y = screenRect.midY - windowRect.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        window.makeKeyAndOrderFront(nil)
        cropperWindow = window
    }
    
    private func presentVideoCropper(for url: URL, completion: @escaping (URL?) -> Void) {
        if #available(macOS 12.0, *) {
            let cropperView = VideoCropperView(videoURL: url, onComplete: { processedURL in
                self.cropperWindow?.close()
                self.cropperWindow = nil
                completion(processedURL)
            }, onCancel: {
                self.cropperWindow?.close()
                self.cropperWindow = nil
                completion(nil)
            })
            
            let hostingController = NSHostingController(rootView: cropperView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "请裁切视频以保证1:1显示"
            window.setContentSize(NSSize(width: 420, height: 0))
            window.styleMask = [.titled, .closable]
            
            if let screen = NSScreen.main {
                let screenRect = screen.visibleFrame
                let windowRect = window.frame
                let x = screenRect.midX - windowRect.width / 2
                let y = screenRect.midY - windowRect.height / 2
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
            
            window.makeKeyAndOrderFront(nil)
            cropperWindow = window
        } else {
            completion(nil)
        }
    }
    
    private func processNonCroppedImage(_ image: NSImage) -> NSImage? {
        let targetSize = CGSize(width: 512, height: 512)
        let scaledImage = NSImage(size: targetSize)
        scaledImage.lockFocus()
        
        NSColor.black.setFill()
        NSBezierPath.fill(NSRect(origin: .zero, size: targetSize))
        
        let drawRect: NSRect
        if image.size.width > 512 {
            drawRect = NSRect(origin: .zero, size: targetSize)
        } else {
            let x = (targetSize.width - image.size.width) / 2.0
            let y = (targetSize.height - image.size.height) / 2.0
            drawRect = NSRect(origin: CGPoint(x: x, y: y), size: image.size)
        }
        
        image.draw(in: drawRect,
                  from: NSRect(origin: .zero, size: image.size),
                  operation: .copy,
                  fraction: 1.0)
        
        scaledImage.unlockFocus()
        return scaledImage
    }
    
    deinit {
        ipCheckTimer?.invalidate()
        ipCheckTimer = nil
    }
} 