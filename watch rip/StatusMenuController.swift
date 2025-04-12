import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

class StatusMenuController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var ipCheckTimer: Timer?
    private var cropperWindow: NSWindow?
    private var currentUploadedFile: String = "暂无文件"
    private var adbDevices: [String] = []
    private var selectedADBDeviceID: String? = nil
    private var adbExecutablePath: String? = nil
    private var adbStatusMenuItem: NSMenuItem?
    private var adbCheckTimer: Timer?
    
    override init() {
        super.init()
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
        let titleItem = NSMenuItem(title: "手表端输入:", action: nil, keyEquivalent: "")
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
        let adbTitleItem = NSMenuItem(title: "ADB 设备 (单选推送):", action: nil, keyEquivalent: "")
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
    
    private func checkADBDevices(completion: @escaping ([String]) -> Void) {
        guard let adbPath = self.adbExecutablePath else {
            print("[checkADBDevices] 无法执行检查，ADB 路径未知")
            self.updateMenuWithADBError("ADB 未找到")
            completion([])
            return
        }

        print("[checkADBDevices] 开始使用路径 '\(adbPath)' 检查设备...")
        runADBCommand(adbPath: adbPath, arguments: ["devices"]) { [weak self] success, output in
            guard let self = self else { return }
            var devices: [String] = []
            if success {
                let lines = output.components(separatedBy: .newlines)
                for line in lines.dropFirst() {
                    let components = line.components(separatedBy: "\t").filter { !$0.isEmpty }
                    if components.count >= 2 && components[1] == "device" {
                        devices.append(components[0].trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                print("[checkADBDevices] 检查成功，发现设备: \(devices)")
                self.updateMenuWithADBDevices(devices)
            } else {
                print("[checkADBDevices] ADB devices 命令失败: \(output)")
                self.updateMenuWithADBError("ADB 命令失败")
            }
            completion(devices)
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
    
    private func updateMenuWithADBDevices(_ devices: [String]) {
        guard let menu = self.statusItem.menu else { return }
        print("[updateMenuWithADBDevices] 正在使用设备列表更新菜单: \(devices)")
        let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备 (单选推送):")
        guard adbTitleIndex != -1 else {
             print("[updateMenuWithADBDevices] 错误：未找到 ADB 标题菜单项")
             return
         }

        // 比较当前显示的设备列表和新列表，如果相同则跳过大部分UI更新
        let currentDeviceItems = menu.items.filter { $0.action == #selector(selectADBDevice(_:)) }
        let currentDeviceIDs = currentDeviceItems.compactMap { $0.representedObject as? String }
        if currentDeviceIDs == devices {
            // 列表未变，只需确保选中状态正确
            print("[updateMenuWithADBDevices] 设备列表未改变，仅检查选中状态。")
            // 检查当前选中的设备是否仍然有效
            if selectedADBDeviceID != nil && !devices.contains(selectedADBDeviceID!) {
                print("[updateMenuWithADBDevices] 之前选中的设备 '\(selectedADBDeviceID!)' 不再存在，重新选择第一个。")
                selectedADBDeviceID = devices.first
            } else if selectedADBDeviceID == nil && !devices.isEmpty {
                 print("[updateMenuWithADBDevices] 之前未选中，自动选择第一个设备。")
                 selectedADBDeviceID = devices.first
            }
            // 更新菜单项的选中状态
             for item in currentDeviceItems {
                 if let id = item.representedObject as? String {
                     item.state = (id == selectedADBDeviceID) ? .on : .off
                 }
             }
             // self.adbDevices = devices // 列表未变，无需更新存储
            return // 跳过后续的移除和添加
        }
        
        print("[updateMenuWithADBDevices] 设备列表已改变，重建菜单项。")
        
        // --- 以下是列表变化时的完整重建逻辑 --- 
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
            if selectedADBDeviceID == nil || !devices.contains(selectedADBDeviceID!) {
                selectedADBDeviceID = devices.first
                print("[updateMenuWithADBDevices] (重建时)自动选中第一个设备: \(devices.first!)")
            }
            
            for (index, deviceId) in devices.enumerated() {
                let deviceItem = NSMenuItem(title: deviceId, action: #selector(selectADBDevice(_:)), keyEquivalent: "")
                deviceItem.target = self
                deviceItem.representedObject = deviceId
                deviceItem.isEnabled = true
                if deviceId == self.selectedADBDeviceID {
                    deviceItem.state = .on
                } else {
                    deviceItem.state = .off
                }
                menu.insertItem(deviceItem, at: adbTitleIndex + 1 + index)
            }
        }
        self.adbDevices = devices
    }
    
    @objc private func selectADBDevice(_ sender: NSMenuItem) {
        guard let newlySelectedID = sender.representedObject as? String else { return }

        // 不再允许取消选择，直接进入选择新设备的逻辑
        if let menu = statusItem.menu {
            let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备 (单选推送):")
            if adbTitleIndex != -1 {
                var loopIndex = adbTitleIndex + 1
                while let item = menu.item(at: loopIndex), item !== adbStatusMenuItem, !item.isSeparatorItem {
                    item.state = .off
                    loopIndex += 1
                }
            } else {
                print("错误: 在 selectADBDevice 中未能找到 'ADB 设备 (单选推送):' 菜单项标题")
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

        print("Running ADB: \(adbPath) \(arguments.joined(separator: " "))")

        task.terminationHandler = { process in
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorString = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            DispatchQueue.main.async {
                if process.terminationStatus == 0 {
                    print("ADB Success: \(outputString)")
                    completion?(true, outputString)
                } else {
                    let combinedError = "Exit Code: \(process.terminationStatus)\nOutput: \(outputString)\nError: \(errorString)"
                    print("ADB Error: \(combinedError)")
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
        // 直接使用应用的 files 目录，不再创建子目录
        let remoteDir = "/storage/emulated/0/Android/data/com.example.watchview/files"
        let remoteFilePath = "\(remoteDir)/\(remoteFileName)"

        // 1. 更新状态为"推送中..."
        updateADBStatus("正在推送至 \(deviceId)...", isError: false)

        // 2. 确保目录存在
        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "mkdir", "-p", remoteDir]) { [weak self] successMkdir, _ in
            guard let self = self else { return }
            
            if successMkdir {
                // 3. 清空目录中的所有文件，但保留目录本身
                self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "rm", "-f", "\(remoteDir)/*"]) { [weak self] successClear, _ in
                    guard let self = self else { return }
                    
                    // 4. 推送文件
                    self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "push", localFilePath, remoteFilePath]) { successPush, outputPush in
                        if successPush {
                            // 5. 更新状态为"成功"
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

        let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备 (单选推送):")
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
        let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备 (单选推送):")
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
        adbCheckTimer?.invalidate() // 先停止旧的，以防万一

        // 创建 Timer 实例，但不立即调度
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            print("ADB 定时器触发，开始检查设备...")
            self?.checkADBDevices { devices in
                // 日志已在 checkADBDevices 和 updateMenuWithADBDevices 中添加
            }
        }
        self.adbCheckTimer = timer

        // 将 Timer 添加到 RunLoop 的 common 模式
        RunLoop.current.add(timer, forMode: .common)
    }
} 
