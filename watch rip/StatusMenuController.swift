import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation
import Sparkle

class StatusMenuController: NSObject, NSMenuDelegate, URLSessionDownloadDelegate {
    private var statusItem: NSStatusItem!
    private var ipCheckTimer: Timer?
    private var cropperWindow: NSWindow?
    private var currentUploadedFile: String = "暂无文件"
    private var adbDevices: [String: String] = [:]
    private var selectedADBDeviceID: String? = nil
    private var adbExecutablePath: String? = nil
    private var adbStatusMenuItem: NSMenuItem?
    private var adbCheckTimer: Timer?
    private let updater: SPUStandardUpdaterController
    private var checkUpdatesMenuItem: NSMenuItem?
    
    // 新增：管理 APK 下载
    private var urlSession: URLSession!
    private var currentDownloadTask: URLSessionDownloadTask?
    private var apkDownloadInfo: (version: String, url: URL, length: Int64, destination: URL)? // 存储下载信息
    
    init(updater: SPUStandardUpdaterController) {
        self.updater = updater
        super.init()
        
        // 初始化 URLSession
        // 使用后台 session 可能过于复杂，先用默认 session 并指定 delegate queue
        let configuration = URLSessionConfiguration.default
        self.urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main) // 在主队列处理回调以方便更新 UI
        
        setupStatusItem()
        startIPCheck()
        statusItem.menu?.delegate = self
        findADBPath { [weak self] path in
            self?.adbExecutablePath = path
            self?.checkADBDevices { _ in }
            self?.startADBCheckTimer()
        }
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
        let titleItem = NSMenuItem(title: "WIFI模式下输入:", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        
        let ipItem = NSMenuItem(title: "获取IP中...", action: #selector(copyIPAddress), keyEquivalent: "")
        ipItem.target = self
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
        if let image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil) {
            mediaItem.image = image
        }
        menu.addItem(mediaItem)
        
        // Rive 文件上传选项
        let riveItem = NSMenuItem(title: "上传 Rive 文件", action: #selector(openRivePicker), keyEquivalent: "")
        riveItem.target = self
        if let image = NSImage(systemSymbolName: "doc.badge.arrow.up", accessibilityDescription: nil) {
            riveItem.image = image
        }
        menu.addItem(riveItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 新增：ADB 设备显示区域
        let adbTitleItem = NSMenuItem(title: "ADB 设备", action: nil, keyEquivalent: "")
        adbTitleItem.isEnabled = false
        menu.addItem(adbTitleItem)
        
        // 添加一个临时的"检测中..."项，稍后会被替换
        let detectingItem = NSMenuItem(title: "检测中...", action: nil, keyEquivalent: "")
        detectingItem.isEnabled = false
        detectingItem.tag = 1001 // 标记，便于识别和移除
        menu.addItem(detectingItem)
        
        // 新增：用于显示 ADB 状态的菜单项
        adbStatusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        adbStatusMenuItem?.isHidden = true // 默认隐藏
        adbStatusMenuItem?.isEnabled = false
        menu.addItem(adbStatusMenuItem!)
        
        menu.addItem(NSMenuItem.separator())
        
        // --- 新增：检查更新选项 --- 
        menu.addItem(NSMenuItem.separator()) // 添加分隔符
        
        let item = NSMenuItem(title: "检查更新...", action: #selector(checkForUpdatesMenuItemAction(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        self.checkUpdatesMenuItem = item
        
        // --- 新增：安装手表 App 选项 --- 
        let installItem = NSMenuItem(title: "安装/更新手表 App", action: #selector(installOrUpdateWatchApp(_:)), keyEquivalent: "")
        installItem.target = self
        menu.addItem(installItem)
        
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
                            .foregroundColor: NSColor.black,
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
    
    @objc private func copyIPAddress() {
        if let ip = UploadServer.shared.getLocalIPAddress() {
            let components = ip.split(separator: ":")
            if let ipWithoutPort = components.first.map(String.init) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(ipWithoutPort, forType: .string)
                
                // 提供复制成功的视觉反馈
                if let menu = statusItem.menu {
                    let originalTitle = menu.item(at: 1)?.attributedTitle
                    menu.item(at: 1)?.attributedTitle = NSAttributedString(
                        string: "已复制",
                        attributes: [
                            .foregroundColor: NSColor.systemGreen,
                            .font: NSFont.systemFont(ofSize: 14, weight: .semibold)
                        ]
                    )
                    
                    // 1秒后恢复原始显示
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        menu.item(at: 1)?.attributedTitle = originalTitle
                    }
                }
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
        
        // 生成临时目录名和最终压缩包名称
        let timestamp = Int(Date().timeIntervalSince1970)
        let tempDir = uploadDir.appendingPathComponent("temp_\(timestamp)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        processFiles(files, index: 0, tempDir: tempDir) {
            // 根据文件数量决定压缩包的命名方式
            let zipFileName: String
            if files.count == 1 {
                // 单个文件：使用源文件名
                zipFileName = files[0].deletingPathExtension().lastPathComponent + ".zip"
            } else {
                // 多个文件：使用 月-日 时:分 格式，去掉方括号
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "MM-dd HH:mm"
                zipFileName = "\(dateFormatter.string(from: Date())).zip"
            }
            
            let zipURL = uploadDir.appendingPathComponent(zipFileName)
            var success = false
            do {
                try fm.zipItem(at: tempDir, to: zipURL, shouldKeepParent: false)
                try? fm.removeItem(at: tempDir)
                self.updateCurrentFile(zipFileName)
                UploadServer.shared.notifyClients()
                success = true
            } catch {
                print("压缩媒体文件失败: \(error)")
            }

            if success, let deviceId = self.selectedADBDeviceID, let adbPath = self.adbExecutablePath {
                self.pushFileToDevice(adbPath: adbPath, deviceId: deviceId, localFilePath: zipURL.path, remoteFileName: zipFileName)
            } else if self.selectedADBDeviceID != nil && self.adbExecutablePath == nil {
                self.updateADBStatus("错误: 未找到ADB路径", isError: true)
            }
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
        
        // 使用原始文件名
        let destURL = uploadDir.appendingPathComponent(fileURL.lastPathComponent)
        var success = false
        do {
            try fm.copyItem(at: fileURL, to: destURL)
            self.updateCurrentFile(fileURL.lastPathComponent)
            UploadServer.shared.notifyClients()
            success = true
        } catch {
            print("本地复制Rive文件失败: \(error.localizedDescription)")
        }

        if success, let deviceId = self.selectedADBDeviceID, let adbPath = self.adbExecutablePath {
            self.pushFileToDevice(adbPath: adbPath, deviceId: deviceId, localFilePath: destURL.path, remoteFileName: destURL.lastPathComponent)
        } else if self.selectedADBDeviceID != nil && self.adbExecutablePath == nil {
            self.updateADBStatus("错误: 未找到ADB路径", isError: true)
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
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "flv"]
        let fm = FileManager.default
        // 目标文件名统一使用 png (图片) 或 mp4 (视频)
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let destURL = tempDir.appendingPathComponent(baseName)

        // 定义下一步操作
        let nextStep = { [weak self] in
            self?.processFiles(files, index: index + 1, tempDir: tempDir, completion: completion)
        }

        if imageExtensions.contains(ext) {
            // --- 图片处理 --- 
            let finalDestURL = destURL.appendingPathExtension("png") // 确保是 png
            if let image = NSImage(contentsOf: fileURL) {
                let width = image.size.width
                let height = image.size.height
                if abs(width - height) > 1 { // 需要裁剪
                    presentImageCropper(for: image) { [weak self] cropped in
                        guard let self = self else { nextStep(); return }
                        let finalImage = cropped ?? image // 取裁剪结果或原始图
                        // 缩放至512x512
                        if let processed = self.processNonCroppedImage(finalImage),
                           let tiffData = processed.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiffData),
                           let data = rep.representation(using: .png, properties: [:]) {
                            try? data.write(to: finalDestURL)
                        } else {
                            try? fm.copyItem(at: fileURL, to: destURL.appendingPathExtension(fileURL.pathExtension)) // 失败则拷贝原始扩展名
                        }
                        nextStep()
                    }
                    return // 等待裁剪回调
                } else { // 已经是1:1
                    // 直接缩放至512x512
                    if let processed = processNonCroppedImage(image),
                       let tiffData = processed.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiffData),
                       let data = rep.representation(using: .png, properties: [:]) {
                        try? data.write(to: finalDestURL)
                    } else {
                         try? fm.copyItem(at: fileURL, to: destURL.appendingPathExtension(fileURL.pathExtension))
                    }
                    nextStep()
                }
            } else {
                try? fm.copyItem(at: fileURL, to: destURL.appendingPathExtension(fileURL.pathExtension))
                nextStep()
            }
        } else if videoExtensions.contains(ext) {
            // --- 视频处理 --- 
            let finalDestURL = destURL.appendingPathExtension("mp4") // 确保是 mp4
            let asset = AVAsset(url: fileURL)
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                print("Skipping non-video file or video without track: \(fileURL.lastPathComponent)")
                try? fm.copyItem(at: fileURL, to: destURL.appendingPathExtension(fileURL.pathExtension))
                nextStep()
                return
            }

            let naturalSize = videoTrack.naturalSize
            let needsCropping = abs(naturalSize.width - naturalSize.height) > 1

            if needsCropping {
                if #available(macOS 12.0, *) {
                    presentVideoCropper(for: fileURL) { [weak self] processedURL in
                        guard let self = self else { nextStep(); return }
                        let inputURLForResize = processedURL ?? fileURL // 取裁剪结果或原始视频
                        print("Resizing video (after crop attempt) \(inputURLForResize.lastPathComponent) to 512x512...")
                        self.resizeVideo(inputURL: inputURLForResize, outputURL: finalDestURL) { success in
                            if !success {
                                print("Video resizing failed for \(inputURLForResize.lastPathComponent). Copying original.")
                                try? fm.copyItem(at: fileURL, to: destURL.appendingPathExtension(fileURL.pathExtension))
                            }
                            // 清理临时的裁剪文件 (如果存在且不同于原始文件)
                            if let cropped = processedURL, cropped != fileURL {
                                 try? fm.removeItem(at: cropped)
                             }
                            nextStep()
                        }
                    }
                    return // 等待裁剪和缩放回调
                } else {
                    print("Video cropping not available on this macOS version. Resizing original.")
                    self.resizeVideo(inputURL: fileURL, outputURL: finalDestURL) { success in
                        if !success {
                            print("Video resizing failed for \(fileURL.lastPathComponent). Copying original.")
                            try? fm.copyItem(at: fileURL, to: destURL.appendingPathExtension(fileURL.pathExtension))
                        }
                        nextStep()
                    }
                    return // 等待缩放回调
                }
            } else { // 已经是1:1
                print("Resizing 1:1 video \(fileURL.lastPathComponent) to 512x512...")
                self.resizeVideo(inputURL: fileURL, outputURL: finalDestURL) { success in
                    if !success {
                        print("Video resizing failed for \(fileURL.lastPathComponent). Copying original.")
                        try? fm.copyItem(at: fileURL, to: destURL.appendingPathExtension(fileURL.pathExtension))
                    }
                    nextStep()
                }
                return // 等待缩放回调
            }
        } else {
            // --- 其他文件类型 --- 
            print("Copying non-image/video file: \(fileURL.lastPathComponent)")
            try? fm.copyItem(at: fileURL, to: destURL.appendingPathExtension(fileURL.pathExtension))
            nextStep()
        }
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
        
        // 对于1:1的图片，直接拉伸到512×512
        let drawRect = NSRect(origin: .zero, size: targetSize)
        
        image.draw(in: drawRect,
                  from: NSRect(origin: .zero, size: image.size),
                  operation: .copy,
                  fraction: 1.0)
        
        scaledImage.unlockFocus()
        return scaledImage
    }
    
    // --- 新增：视频缩放函数 ---
    private func resizeVideo(inputURL: URL, outputURL: URL, targetSize: CGSize = CGSize(width: 512, height: 512), completion: @escaping (Bool) -> Void) {
        let asset = AVAsset(url: inputURL)
        
        // 使用 .movielens 或类似的中等质量预设，如果不存在则用 HighestQuality
        let preset = AVAssetExportSession.exportPresets(compatibleWith: asset).contains(AVAssetExportPreset1280x720) ? AVAssetExportPreset1280x720 : AVAssetExportPresetHighestQuality
        
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            print("Error creating export session for \(inputURL)")
            completion(false)
            return
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4 // 强制输出 MP4
        exporter.shouldOptimizeForNetworkUse = true

        // 创建视频组合以进行缩放
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            print("No video track found in \(inputURL)")
            completion(false)
            return
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = targetSize
        // 修正帧率获取和设置
        let frameRate = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)

        // 计算缩放变换，保持宽高比并居中
        let naturalSize = videoTrack.naturalSize
        let preferredTransform = videoTrack.preferredTransform
        let transformedSize = naturalSize.applying(preferredTransform)
        let videoWidth = abs(transformedSize.width)
        let videoHeight = abs(transformedSize.height)

        let scaleX = targetSize.width / videoWidth
        let scaleY = targetSize.height / videoHeight
        let scaleFactor = min(scaleX, scaleY)

        let scaledWidth = videoWidth * scaleFactor
        let scaledHeight = videoHeight * scaleFactor
        let posX = (targetSize.width - scaledWidth) / 2.0
        let posY = (targetSize.height - scaledHeight) / 2.0

        var finalTransform = preferredTransform
        finalTransform = finalTransform.concatenating(CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        finalTransform = finalTransform.concatenating(CGAffineTransform(translationX: posX, y: posY))

        layerInstruction.setTransform(finalTransform, at: .zero)

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        exporter.videoComposition = videoComposition

        // 确保输出目录存在并移除旧文件
        let outputDir = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed:
                    print("Video resized successfully to \(outputURL.path)")
                    completion(true)
                case .failed:
                    print("Video resizing failed: \(exporter.error?.localizedDescription ?? "Unknown error")")
                    completion(false)
                case .cancelled:
                    print("Video resizing cancelled.")
                    completion(false)
                default:
                    completion(false)
                }
            }
        }
    }
    // --- 结束 新增：视频缩放函数 ---

    deinit {
        ipCheckTimer?.invalidate()
        ipCheckTimer = nil
        adbCheckTimer?.invalidate()
        adbCheckTimer = nil
        print("定时器已停止")
    }
    
    func menuWillOpen(_ menu: NSMenu) {
        print("菜单即将打开，手动触发 ADB 设备检查...")
        updateADBDeviceList()
        adbStatusMenuItem?.isHidden = true
    }
    
    private func updateADBDeviceList() {
        if adbExecutablePath == nil {
            findADBPath { [weak self] path in
                self?.adbExecutablePath = path
                self?.checkADBDevices { _ in }
            }
        } else {
            checkADBDevices { _ in }
        }
    }
    
    private func checkADBDevices(completion: @escaping ([String: String]) -> Void) {
        guard let adbPath = self.adbExecutablePath else {
            print("[checkADBDevices] 无法执行检查，ADB 路径未知")
            self.updateMenuWithADBError("ADB 未找到")
            completion([:])
            return
        }

        runADBCommand(adbPath: adbPath, arguments: ["devices"]) { [weak self] success, output in
            guard let self = self else { completion([:]); return }
            
            var serials: [String] = []
            if success {
                let lines = output.components(separatedBy: .newlines)
                for line in lines.dropFirst() {
                    let components = line.components(separatedBy: "\t").filter { !$0.isEmpty }
                    if components.count >= 2 && components[1] == "device" {
                        serials.append(components[0].trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                
                if serials.isEmpty {
                    self.updateMenuWithADBDevices([:])
                    completion([:])
                    return
                }
                
                var devicesInfo: [String: String] = [:]
                let group = DispatchGroup()
                let queue = DispatchQueue(label: "com.jadon7.watchrip.getdevicename", attributes: .concurrent)
                
                for serial in serials {
                    group.enter()
                    queue.async {
                        self.runADBCommand(adbPath: adbPath, arguments: ["-s", serial, "shell", "getprop", "ro.product.model"]) { nameSuccess, nameOutput in
                            if nameSuccess && !nameOutput.isEmpty {
                                devicesInfo[serial] = nameOutput
                            } else {
                                print("[checkADBDevices] 设备 \(serial) 名称获取失败或为空，使用序列号。错误: \(nameOutput)")
                                devicesInfo[serial] = serial
                            }
                            group.leave()
                        }
                    }
                }
                
                group.notify(queue: .main) {
                    self.updateMenuWithADBDevices(devicesInfo)
                    completion(devicesInfo)
                }
                
            } else {
                print("[checkADBDevices] ADB devices 命令失败: \(output)")
                self.updateMenuWithADBError("ADB 命令失败")
                completion([:])
            }
        }
    }
    
    private func findADBPath(completion: @escaping (String?) -> Void) {
        if let existingPath = self.adbExecutablePath {
            completion(existingPath)
            return
        }

        var foundPath: String? = nil

        if let bundledADBPath = Bundle.main.path(forResource: "adb", ofType: nil) {
             if FileManager.default.isExecutableFile(atPath: bundledADBPath) {
                 print("Found bundled adb at: \(bundledADBPath)")
                 foundPath = bundledADBPath
             } else {
                 do {
                     try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledADBPath)
                     if FileManager.default.isExecutableFile(atPath: bundledADBPath) {
                         print("Successfully set executable permission for bundled adb at: \(bundledADBPath)")
                         foundPath = bundledADBPath
                     } else {
                          print("Found bundled adb file, but could not make it executable: \(bundledADBPath)")
                     }
                 } catch {
                     print("Error setting executable permission for bundled adb at \(bundledADBPath): \(error)")
                 }
             }
        }

        if foundPath == nil {
            print("Bundled adb not found or not executable, trying system paths...")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["which", "adb"]

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            task.terminationHandler = { process in
                var systemPath: String? = nil
                if process.terminationStatus == 0 {
                    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let path = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let path = path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                        print("Found system adb via 'which': \(path)")
                        systemPath = path
                    }
                }
                if systemPath == nil {
                    let fallbackPath = "/usr/local/bin/adb"
                    if FileManager.default.isExecutableFile(atPath: fallbackPath) {
                         print("'which adb' failed or result not executable, using fallback path: \(fallbackPath)")
                         systemPath = fallbackPath
                    }
                }
                 if systemPath == nil {
                     let homeDir = FileManager.default.homeDirectoryForCurrentUser
                     let sdkPath = homeDir.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
                     if FileManager.default.isExecutableFile(atPath: sdkPath) {
                         print("'which adb' and Homebrew path failed or not executable, using standard SDK path: \(sdkPath)")
                         systemPath = sdkPath
                     }
                 }

                self.adbExecutablePath = systemPath ?? foundPath
                DispatchQueue.main.async {
                    completion(self.adbExecutablePath)
                }
            }

            do {
                try task.run()
            } catch {
                print("Failed to launch 'which adb' process: \(error)")
                 var fallbackSystemPath: String? = nil
                 let fallbackPath = "/usr/local/bin/adb"
                 let sdkPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
                 if FileManager.default.isExecutableFile(atPath: fallbackPath) {
                     fallbackSystemPath = fallbackPath
                 } else if FileManager.default.isExecutableFile(atPath: sdkPath) {
                     fallbackSystemPath = sdkPath
                 }
                self.adbExecutablePath = fallbackSystemPath ?? foundPath
                DispatchQueue.main.async {
                    completion(self.adbExecutablePath)
                }
            }
        } else {
             self.adbExecutablePath = foundPath
             DispatchQueue.main.async {
                 completion(foundPath)
             }
        }
    }
    
    private func updateMenuWithADBDevices(_ devices: [String: String]) {
        guard let menu = self.statusItem.menu else { return }
        let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备")
        guard adbTitleIndex != -1 else {
             print("[updateMenuWithADBDevices] 错误：未找到 ADB 标题菜单项")
             return
         }

        let currentDeviceItems = menu.items.filter { $0.action == #selector(selectADBDevice(_:)) }
        let currentDeviceIDs = currentDeviceItems.compactMap { $0.representedObject as? String }.sorted()
        let newDeviceIDs = devices.keys.sorted()
        
        if currentDeviceIDs == newDeviceIDs {
            if selectedADBDeviceID != nil && !devices.keys.contains(selectedADBDeviceID!) {
                 print("[updateMenuWithADBDevices] 之前选中的设备 \'\(selectedADBDeviceID!)\' 不再存在，重新选择第一个。")
                 selectedADBDeviceID = devices.keys.sorted().first
            } else if selectedADBDeviceID == nil && !devices.isEmpty {
                 print("[updateMenuWithADBDevices] 之前未选中，自动选择第一个设备。")
                 selectedADBDeviceID = devices.keys.sorted().first
            }
             for item in currentDeviceItems {
                 if let serial = item.representedObject as? String,
                    let deviceName = devices[serial] {
                     let title = (deviceName == serial) ? serial : "\(deviceName) (\(serial))"
                     item.title = title
                     item.state = (serial == selectedADBDeviceID) ? .on : .off
                 }
             }
            self.adbDevices = devices
            return
        }
        
        let currentIndex = adbTitleIndex + 1
        while let itemToRemove = menu.item(at: currentIndex),
              itemToRemove !== adbStatusMenuItem,
              !itemToRemove.isSeparatorItem { 
            menu.removeItem(at: currentIndex)
        }

        if devices.isEmpty {
            let noDeviceItem = NSMenuItem(title: "无设备连接", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            menu.insertItem(noDeviceItem, at: adbTitleIndex + 1)
            selectedADBDeviceID = nil
        } else {
            let sortedSerials = devices.keys.sorted()
            if selectedADBDeviceID == nil || !sortedSerials.contains(selectedADBDeviceID!) {
                selectedADBDeviceID = sortedSerials.first
                if let selectedID = selectedADBDeviceID {
                     print("[updateMenuWithADBDevices] (重建时)自动选中第一个设备: \(selectedID)")
                }
            }
            
            for (index, serial) in sortedSerials.enumerated() {
                let deviceName = devices[serial] ?? serial
                let title = (deviceName == serial) ? serial : "\(deviceName) (\(serial))"
                
                let deviceItem = NSMenuItem(title: title, action: #selector(selectADBDevice(_:)), keyEquivalent: "")
                deviceItem.target = self
                deviceItem.representedObject = serial
                deviceItem.isEnabled = true
                deviceItem.state = (serial == selectedADBDeviceID) ? .on : .off
                menu.insertItem(deviceItem, at: adbTitleIndex + 1 + index)
            }
        }
        self.adbDevices = devices
    }
    
    @objc private func selectADBDevice(_ sender: NSMenuItem) {
        guard let newlySelectedID = sender.representedObject as? String else { return }

        if let menu = statusItem.menu {
            let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备")
            if adbTitleIndex != -1 {
                var loopIndex = adbTitleIndex + 1
                while let item = menu.item(at: loopIndex), item !== adbStatusMenuItem, !item.isSeparatorItem {
                    item.state = .off
                    loopIndex += 1
                }
            }
        }
        selectedADBDeviceID = newlySelectedID
        sender.state = .on
        print("Selected ADB device: \(selectedADBDeviceID!)")
    }
    
    private func runADBCommand(adbPath: String, arguments: [String], completion: ((Bool, String) -> Void)? = nil) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: adbPath)
        task.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        task.terminationHandler = { process in
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    completion?(true, outputString)
                } else {
                    let combinedError = "Exit Code: \(process.terminationStatus)\nOutput: \(outputString)\nError: \(errorString)"
                    completion?(false, combinedError)
                }
            }
        }

        do {
            try task.run()
        } catch {
            print("Failed to launch adb process (\(adbPath)): \(error)")
            DispatchQueue.main.async {
                 completion?(false, "启动 ADB 进程失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func pushFileToDevice(adbPath: String, deviceId: String, localFilePath: String, remoteFileName: String) {
        let remoteDir = "/storage/emulated/0/Android/data/com.example.watchview/files"
        let remoteFilePath = "\(remoteDir)/\(remoteFileName)"

        updateADBStatus("正在推送至 \(deviceId)...", isError: false)

        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "mkdir", "-p", remoteDir]) { [weak self] successMkdir, _ in
            guard let self = self else { return }
            
            if successMkdir {
                self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "rm", "-f", "\(remoteDir)/*"]) { [weak self] successClear, _ in
                    guard let self = self else { return }
                    
                    self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "push", localFilePath, remoteFilePath]) { successPush, outputPush in
                        if successPush {
                            self.updateADBStatus("推送成功!", isError: false)
                        } else {
                            self.updateADBStatus("推送失败: \(outputPush)", isError: true)
                        }
                    }
                }
            } else {
                self.updateADBStatus("创建目录失败", isError: true)
            }
        }
    }
    
    private func updateADBStatus(_ message: String, isError: Bool) {
        guard let statusItem = adbStatusMenuItem, let menu = statusItem.menu else { return }

        let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备")
        guard adbTitleIndex != -1 else { return }
        var insertIndex = adbTitleIndex + 1
        while let item = menu.item(at: insertIndex), item.action == #selector(selectADBDevice(_:)) || item.title == "无设备连接" || item.title == "检测中..." {
            insertIndex += 1
        }

        if menu.index(of: statusItem) != insertIndex {
             if menu.index(of: statusItem) != -1 { menu.removeItem(statusItem) }
             menu.insertItem(statusItem, at: insertIndex)
        }

        statusItem.isHidden = false
        statusItem.attributedTitle = NSAttributedString(
            string: message,
            attributes: [
                .foregroundColor: isError ? NSColor.systemRed : NSColor.systemGreen,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        )

        if !isError {
             DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak statusItem] in
                  statusItem?.isHidden = true
             }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak statusItem] in
                 statusItem?.isHidden = true
            }
        }
    }
    
    private func updateMenuWithADBError(_ errorMessage: String) {
        guard let menu = self.statusItem.menu else { return }
        let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备")
        guard adbTitleIndex != -1 else { return }

        let currentIndex = adbTitleIndex + 1
        while let itemToRemove = menu.item(at: currentIndex),
              itemToRemove !== adbStatusMenuItem,
              !itemToRemove.isSeparatorItem {
            menu.removeItem(at: currentIndex)
        }

        let errorItem = NSMenuItem(title: errorMessage, action: nil, keyEquivalent: "")
        errorItem.isEnabled = false
        errorItem.attributedTitle = NSAttributedString(
            string: errorMessage,
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        menu.insertItem(errorItem, at: adbTitleIndex + 1)
    }

    private func startADBCheckTimer() {
        print("启动 ADB 定时检查 (间隔 5 秒)")
        adbCheckTimer?.invalidate()

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkADBDevices { devices in
                // 日志已在 checkADBDevices 和 updateMenuWithADBDevices 中移除
            }
        }
        self.adbCheckTimer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    @objc private func checkForUpdatesMenuItemAction(_ sender: NSMenuItem) {
        updater.checkForUpdates(sender)
    }

    func updateCheckUpdatesMenuItemTitle(hasUpdate: Bool) {
        DispatchQueue.main.async { // 确保在主线程更新 UI
            if hasUpdate {
                self.checkUpdatesMenuItem?.title = "发现新版本！"
                // (可选) 添加视觉提示，比如加粗或改变颜色
                // self.checkUpdatesMenuItem?.attributedTitle = NSAttributedString(...) 
            } else {
                self.checkUpdatesMenuItem?.title = "检查更新..."
                // (可选) 恢复默认样式
                // self.checkUpdatesMenuItem?.attributedTitle = nil 
            }
        }
    }

    @objc private func installOrUpdateWatchApp(_ sender: NSMenuItem) {
        print("开始执行安装/更新手表 App 流程")
        
        guard let deviceId = selectedADBDeviceID else {
            updateADBStatus("请先选择一个 ADB 设备", isError: true)
            return
        }
        guard let adbPath = adbExecutablePath else {
            updateADBStatus("错误: 未找到 ADB 路径", isError: true)
            return
        }

        updateADBStatus("检查手表 App 版本...", isError: false)
        
        let packageName = "com.example.watchview"
        let command = "dumpsys package \(packageName) | grep versionName"
        
        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", command]) { [weak self] success, output in
            guard let self = self else { return }
            
            var deviceVersion: String? = nil
            if success {
                if let range = output.range(of: "versionName=") {
                    let versionString = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !versionString.isEmpty && versionString.contains(".") { 
                        deviceVersion = versionString
                        print("设备 \(deviceId) 上找到 \(packageName) 版本: \(deviceVersion!)")
                        self.updateADBStatus("设备版本: \(deviceVersion!) / 线上检查中...", isError: false)
                    } else {
                         print("从 dumpsys 输出中解析版本号失败或格式无效: \(output)")
                    }
                }
            }
            if deviceVersion == nil {
                 print("未在设备 \(deviceId) 上找到 \(packageName) 或获取版本失败。错误/输出: \(output)")
                 self.updateADBStatus("设备未安装App / 线上检查中...", isError: false)
            }

            self.fetchOnlineVersionAndProceed(deviceVersion: deviceVersion, deviceId: deviceId, adbPath: adbPath)
        }
    }
    
    private func fetchOnlineVersionAndProceed(deviceVersion: String?, deviceId: String, adbPath: String) {
        let appcastURLString = "https://raw.githubusercontent.com/jadon7/Watch-RIP-MAC/feature/wear-app-installer/wear_os_appcast.xml"
        guard let url = URL(string: appcastURLString) else {
            print("Wear OS Appcast URL 无效: \(appcastURLString)")
            updateADBStatus("错误: Appcast URL 无效", isError: true)
            return
        }

        updateADBStatus("线上检查中...", isError: false)

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                print("下载 Wear OS Appcast 失败: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.updateADBStatus("错误: 无法检查更新", isError: true)
                }
                return
            }
            
            guard let data = data else {
                print("Wear OS Appcast 下载的数据为空")
                DispatchQueue.main.async {
                    self.updateADBStatus("错误: 更新信息为空", isError: true)
                }
                return
            }

            let parser = XMLParser(data: data)
            let delegate = WearOSAppcastParserDelegate()
            parser.delegate = delegate
            
            if parser.parse() {
                guard let onlineVersion = delegate.latestVersionName, 
                      let downloadURL = delegate.downloadURL, 
                      let downloadLengthStr = delegate.downloadLength else {
                    print("解析 Appcast 成功，但未能提取到完整的版本信息")
                    DispatchQueue.main.async {
                        self.updateADBStatus("错误: 更新信息不完整", isError: true)
                    }
                    return
                }
                
                print("线上最新版本: \(onlineVersion), 下载地址: \(downloadURL), 大小: \(downloadLengthStr)")
                
                DispatchQueue.main.async {
                    if let devVersion = deviceVersion {
                        switch devVersion.compare(onlineVersion, options: .numeric) {
                        case .orderedSame, .orderedDescending:
                            print("设备版本 (\(devVersion)) >= 线上版本 (\(onlineVersion))，无需更新。")
                            self.updateADBStatus("手表 App 已是最新版", isError: false)
                            return
                        case .orderedAscending:
                            print("设备版本 (\(devVersion)) < 线上版本 (\(onlineVersion))，需要更新。")
                            self.updateADBStatus("发现新版本: \(onlineVersion)", isError: false)
                            self.checkCacheAndDownloadAPK(onlineVersion: onlineVersion, downloadURL: downloadURL, downloadLengthStr: downloadLengthStr, deviceId: deviceId, adbPath: adbPath)
                        }
                    } else {
                        print("设备未安装或无法获取版本，准备安装线上版本 \(onlineVersion)。")
                        self.updateADBStatus("准备安装版本: \(onlineVersion)", isError: false)
                        self.checkCacheAndDownloadAPK(onlineVersion: onlineVersion, downloadURL: downloadURL, downloadLengthStr: downloadLengthStr, deviceId: deviceId, adbPath: adbPath)
                    }
                }

            } else {
                print("解析 Wear OS Appcast 失败")
                DispatchQueue.main.async {
                    self.updateADBStatus("错误: 解析更新信息失败", isError: true)
                }
            }
        }
        task.resume()
    }

    private func checkCacheAndDownloadAPK(onlineVersion: String, downloadURL: String, downloadLengthStr: String, deviceId: String, adbPath: String) {
        
        guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            updateADBStatus("错误: 无法访问缓存目录", isError: true)
            return
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.jadon7.watchrip"
        let cacheDir = appSupportDir.appendingPathComponent(bundleId).appendingPathComponent("APKCache")
        
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("创建缓存目录失败: \(error)")
            updateADBStatus("错误: 无法创建缓存", isError: true)
            return
        }
        
        let apkFileName = "watch_view_\(onlineVersion).apk"
        let destinationURL = cacheDir.appendingPathComponent(apkFileName)
        
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            print("发现本地缓存的最新 APK: \(destinationURL.path)")
            updateADBStatus("准备安装本地缓存的 App...", isError: false)
            installAPKFromLocalPath(localAPKPath: destinationURL.path, deviceId: deviceId, adbPath: adbPath)
        } else {
            print("本地未找到版本 \(onlineVersion) 的 APK，开始下载...")
            guard let url = URL(string: downloadURL), let length = Int64(downloadLengthStr) else {
                updateADBStatus("错误: 下载信息无效", isError: true)
                return
            }
            
            if currentDownloadTask != nil {
                updateADBStatus("已有下载任务进行中...", isError: false)
                return
            }
            
            self.apkDownloadInfo = (version: onlineVersion, url: url, length: length, destination: destinationURL)
            
            currentDownloadTask = urlSession.downloadTask(with: url)
            currentDownloadTask?.resume()
            updateADBStatus("开始下载手表 App (0%)...", isError: false)
        }
    }

    private func installAPKFromLocalPath(localAPKPath: String, deviceId: String, adbPath: String) {
        updateADBStatus("正在安装手表 App...", isError: false)
        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "install", "-r", localAPKPath]) { [weak self] success, output in
            if success && output.lowercased().contains("success") {
                self?.updateADBStatus("手表 App 安装成功!", isError: false)
            } else {
                self?.updateADBStatus("安装失败: \(output)", isError: true)
            }
        }
    }

    // MARK: - URLSessionDownloadDelegate Methods

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard downloadTask == currentDownloadTask, let info = apkDownloadInfo else { return }
        
        let expectedLength = (totalBytesExpectedToWrite != NSURLSessionTransferSizeUnknown) ? totalBytesExpectedToWrite : info.length
        
        if expectedLength > 0 {
            let progress = Double(totalBytesWritten) / Double(expectedLength)
            let percentage = Int(progress * 100)
            updateADBStatus("下载中 (\(percentage)%)...", isError: false)
        } else {
            let downloadedMB = String(format: "%.1f MB", Double(totalBytesWritten) / (1024 * 1024))
            updateADBStatus("下载中 (\(downloadedMB))...", isError: false)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        print("APK 下载完成，临时文件位于: \(location.path)")
        guard let info = apkDownloadInfo else {
            print("错误: 下载完成但 apkDownloadInfo 为空")
            updateADBStatus("下载错误 (内部信息丢失)", isError: true)
            currentDownloadTask = nil
            return
        }
        
        let destinationURL = info.destination
        let fm = FileManager.default
        try? fm.removeItem(at: destinationURL)
        do {
            try fm.moveItem(at: location, to: destinationURL)
            print("APK 已移动到缓存目录: \(destinationURL.path)")
            
            currentDownloadTask = nil
            self.apkDownloadInfo = nil
            
            if let deviceId = selectedADBDeviceID, let adbPath = adbExecutablePath {
                installAPKFromLocalPath(localAPKPath: destinationURL.path, deviceId: deviceId, adbPath: adbPath)
            } else {
                 updateADBStatus("错误: 无法开始安装 (设备未选或 ADB 路径丢失)", isError: true)
            }
            
        } catch {
            print("移动 APK 文件失败: \(error)")
            updateADBStatus("下载错误 (无法保存文件)", isError: true)
            currentDownloadTask = nil
            self.apkDownloadInfo = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("URLSession 任务出错: \(error.localizedDescription)")
            if task == currentDownloadTask {
                 updateADBStatus("下载失败: \(error.localizedDescription)", isError: true)
                 currentDownloadTask = nil
                 apkDownloadInfo = nil
            }
        } else {
            if task == currentDownloadTask && task.response != nil {
                 print("下载任务完成，但可能未成功保存文件 (检查 didFinishDownloadingTo)。")
            }
        }
    }

    fileprivate class WearOSAppcastParserDelegate: NSObject, XMLParserDelegate {
        var latestVersionName: String?
        var downloadURL: String?
        var downloadLength: String?
        private var currentElement: String = ""
        private var foundFirstItem = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            currentElement = elementName
            if elementName == "item" && !foundFirstItem { }
            else if elementName == "enclosure" && !foundFirstItem {
                downloadURL = attributeDict["url"]
                downloadLength = attributeDict["length"]
                foundFirstItem = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return }
            
            if currentElement == "watchrip:versionName" && !foundFirstItem {
                latestVersionName = value
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            currentElement = ""
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            print("[XML Parser] 解析完成。版本: \(latestVersionName ?? "无"), URL: \(downloadURL ?? "无"), 大小: \(downloadLength ?? "无")")
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            print("[XML Parser] 解析错误: \(parseError.localizedDescription)")
            latestVersionName = nil
            downloadURL = nil
            downloadLength = nil
        }
    }
} 
