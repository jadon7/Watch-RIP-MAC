import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension StatusMenuController {

    // MARK: - File Handling and Upload

    @objc func openMediaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType.image, UTType.movie]
        
        // Activate app to bring panel to front
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        panel.begin { [weak self] result in
            if result == .OK {
                self?.handleMediaFiles(panel.urls)
            }
        }
    }
    
    func handleMediaFiles(_ files: [URL]) {
        // Ensure upload directory exists or handle error
        let uploadDir = UploadServer.shared.uploadDirectory
        
        let fm = FileManager.default
        
        // Clear upload directory
        do {
            let existingFiles = try fm.contentsOfDirectory(at: uploadDir, includingPropertiesForKeys: nil)
            for file in existingFiles {
                try fm.removeItem(at: file)
            }
            print("Upload directory cleared.")
        } catch {
            print("Error clearing upload directory: \(error)")
            // Decide if clearing failure should stop the process
        }
        
        // Create temporary directory
        let timestamp = Int(Date().timeIntervalSince1970)
        let tempDir = uploadDir.appendingPathComponent("temp_\(timestamp)", isDirectory: true)
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
             print("Error creating temp directory: \(error)")
             updateADBStatus("创建临时目录失败", isError: true)
             return
        }
        
        // Process files asynchronously
        processFilesAsync(files, index: 0, tempDir: tempDir) { [weak self] zipFilePath, zipFileName in
             guard let self = self else { return }
             // Cleanup temp dir after completion or failure
             try? fm.removeItem(at: tempDir)
             print("Temporary directory removed: \(tempDir.lastPathComponent)")

             if let path = zipFilePath, let name = zipFileName {
                  print("File processing and zipping complete: \(name)")
                  self.updateCurrentFile(name)
                  if let deviceId = self.selectedADBDeviceID, let adbPath = self.adbExecutablePath {
                      // Ensure pushFileToDevice is accessible (should be internal or public in ADB extension)
                      self.pushFileToDevice(adbPath: adbPath, deviceId: deviceId, localFilePath: path.path, remoteFileName: name)
                  } else {
                       // Ensure updateADBStatus is accessible (should be internal or public in ADB extension)
                      self.updateADBStatus("无设备选择，无法推送文件", isError: true)
                  }
              } else {
                  print("File processing or zipping failed.")
                  self.updateCurrentFile("处理或压缩失败")
                  self.updateADBStatus("处理或压缩失败", isError: true)
              }
        }
    }

    // Modified processFilesAsync to pass back the result path/name or nil on failure
    private func processFilesAsync(_ files: [URL], index: Int, tempDir: URL, completion: @escaping (URL?, String?) -> Void) {
        guard index < files.count else {
            // All files processed, now zip them
            let zipFileName: String
            if files.count == 1, let firstFile = files.first {
                zipFileName = firstFile.deletingPathExtension().lastPathComponent + ".zip"
            } else {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
                let dateString = dateFormatter.string(from: Date())
                zipFileName = "\(dateString).zip"
            }
            
            // Ensure upload directory exists before creating zip path
            let uploadDir = UploadServer.shared.uploadDirectory
            let zipFilePath = uploadDir.appendingPathComponent(zipFileName)
            
            // Attempt to remove old zip if it exists
            try? FileManager.default.removeItem(at: zipFilePath)
            
            // Ensure zipDirectory is accessible
            UploadServer.shared.zipDirectory(at: tempDir, to: zipFilePath) { success in
                if success {
                    completion(zipFilePath, zipFileName)
                } else {
                    completion(nil, nil)
                }
            }
            return
        }

        let fileURL = files[index]
        let ext = fileURL.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "heic", "tiff", "bmp"]
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "flv"]
        let fm = FileManager.default

        if imageExtensions.contains(ext) {
            guard let image = NSImage(contentsOf: fileURL) else {
                print("无法加载图片: \(fileURL.lastPathComponent)")
                processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
                return
            }
            let width = image.size.width
            let height = image.size.height

            if abs(width - height) > 1 { // Non 1:1
                self.presentImageCropper(for: image) { [weak self] croppedImage in
                    guard let self = self else { return }
                    let destURL = tempDir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".png")
                    if let cropped = croppedImage, let data = cropped.pngData() {
                        try? data.write(to: destURL)
                        print("图片裁剪并保存为 PNG: \(destURL.lastPathComponent)")
                    } else {
                        print("图片裁剪取消/失败，处理原图: \(fileURL.lastPathComponent)")
                        if let processed = self.processNonCroppedImage(image), let data = processed.pngData() {
                            try? data.write(to: destURL)
                            print("原图处理并保存为 PNG: \(destURL.lastPathComponent)")
                        } else {
                             print("无法处理原图: \(fileURL.lastPathComponent)")
                        }
                    }
                    self.processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
                }
            } else { // Already 1:1
                let destURL = tempDir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".png")
                if let processed = self.processNonCroppedImage(image), let data = processed.pngData() {
                    try? data.write(to: destURL)
                    print("1:1 图片处理并保存为 PNG: \(destURL.lastPathComponent)")
                } else {
                     print("无法处理 1:1 图片: \(fileURL.lastPathComponent)")
                }
                processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
            }
        } else if videoExtensions.contains(ext) {
            let asset = AVAsset(url: fileURL)
            if let videoTrack = asset.tracks(withMediaType: .video).first,
               videoTrack.naturalSize.width != videoTrack.naturalSize.height {
                 // Non 1:1 video
                self.presentVideoCropper(for: fileURL) { [weak self] processedURL in
                     guard let self = self else { return }
                    let destURL = tempDir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".mp4")
                    if let processed = processedURL {
                        do {
                             // Ensure the destination doesn't exist
                             try? fm.removeItem(at: destURL)
                             try fm.moveItem(at: processed, to: destURL)
                             print("视频裁剪并保存为 MP4: \(destURL.lastPathComponent)")
                         } catch {
                             print("移动裁剪后视频失败: \(error), 尝试处理原视频")
                             if let originalProcessed = self.processVideo(fileURL) {
                                 try? fm.removeItem(at: destURL)
                                 try? fm.moveItem(at: originalProcessed, to: destURL)
                                 print("原视频处理并保存为 MP4: \(destURL.lastPathComponent)")
                             } else {
                                  print("无法处理原视频，尝试直接复制")
                                  try? fm.removeItem(at: destURL)
                                  try? fm.copyItem(at: fileURL, to: destURL)
                             }
                         }
                    } else {
                         print("视频裁剪取消/失败，处理原视频: \(fileURL.lastPathComponent)")
                         if let originalProcessed = self.processVideo(fileURL) {
                            try? fm.removeItem(at: destURL)
                             try? fm.moveItem(at: originalProcessed, to: destURL)
                             print("原视频处理并保存为 MP4: \(destURL.lastPathComponent)")
                         } else {
                             print("无法处理原视频，尝试直接复制")
                             try? fm.removeItem(at: destURL)
                             try? fm.copyItem(at: fileURL, to: destURL)
                         }
                    }
                    self.processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
                }
            } else {
                 // Already 1:1 video
                let destURL = tempDir.appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".mp4")
                if let processed = self.processVideo(fileURL) {
                    do {
                         try? fm.removeItem(at: destURL)
                         try fm.moveItem(at: processed, to: destURL)
                         print("1:1 视频处理并保存为 MP4: \(destURL.lastPathComponent)")
                     } catch {
                          print("移动处理后 1:1 视频失败: \(error), 尝试直接复制")
                          try? fm.removeItem(at: destURL)
                          try? fm.copyItem(at: fileURL, to: destURL)
                     }
                } else {
                     print("无法处理 1:1 视频，尝试直接复制")
                     try? fm.removeItem(at: destURL)
                     try? fm.copyItem(at: fileURL, to: destURL)
                }
                processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
            }
        } else { // Other file types
            print("不支持的文件类型，直接复制: \(fileURL.lastPathComponent)")
            let destURL = tempDir.appendingPathComponent(fileURL.lastPathComponent)
             do {
                 try? fm.removeItem(at: destURL)
                 try fm.copyItem(at: fileURL, to: destURL)
             } catch {
                  print("复制其他文件类型失败: \(error)")
             }
            processFilesAsync(files, index: index + 1, tempDir: tempDir, completion: completion)
        }
    }

    // --- Rive File Upload --- 
    @objc func openRivePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        var allowedTypes: [UTType] = []
        if let t = UTType(filenameExtension: "riv") { allowedTypes.append(t) }
        if let t = UTType(filenameExtension: "rive") { allowedTypes.append(t) }
        panel.allowedContentTypes = allowedTypes.isEmpty ? [UTType.data] : allowedTypes
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        panel.begin { [weak self] result in
            if result == .OK {
                self?.handleRiveFile(panel.url)
            }
        }
    }
    
    func handleRiveFile(_ file: URL?) {
        guard let fileURL = file else { return }
        let uploadDir = UploadServer.shared.uploadDirectory
        let fm = FileManager.default
        let destURL = uploadDir.appendingPathComponent(fileURL.lastPathComponent)
        
        // Clear upload directory
        do {
            let existingFiles = try fm.contentsOfDirectory(at: uploadDir, includingPropertiesForKeys: nil)
            for file in existingFiles {
                try fm.removeItem(at: file)
            }
            print("Upload directory cleared for Rive file.")
        } catch {
             print("Error clearing upload directory for Rive: \(error)")
        }
        
        // Copy new Rive file
        do {
            try fm.copyItem(at: fileURL, to: destURL)
            print("Rive 文件复制成功: \(destURL.lastPathComponent)")
            updateCurrentFile(destURL.lastPathComponent)
            
            if let deviceId = selectedADBDeviceID, let adbPath = adbExecutablePath {
                pushFileToDevice(adbPath: adbPath, deviceId: deviceId, localFilePath: destURL.path, remoteFileName: destURL.lastPathComponent)
            } else {
                 updateADBStatus("无设备选择，无法推送文件", isError: true)
            }
        } catch {
            print("Rive 文件复制失败: \(fileURL.lastPathComponent), 错误: \(error)")
            updateCurrentFile("Rive复制失败")
             updateADBStatus("Rive 文件复制失败", isError: true)
        }
    }

    // --- Cropping and Processing Helpers ---
    
    func presentImageCropper(for image: NSImage, completion: @escaping (NSImage?) -> Void) {
        // Assume ImageCropperView exists
        let cropperView = ImageCropperView(originalImage: image, onComplete: { [weak self] croppedImage in
            self?.cropperWindow?.close()
            self?.cropperWindow = nil
            completion(croppedImage)
        }, onCancel: { [weak self] in
            self?.cropperWindow?.close()
            self?.cropperWindow = nil
            completion(nil)
        })
        
        let hostingController = NSHostingController(rootView: cropperView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "请裁切图片以保证1:1显示"
        window.setContentSize(NSSize(width: 420, height: 0))
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.cropperWindow = window // Assign to the property
    }

    func processNonCroppedImage(_ image: NSImage) -> NSImage? {
        let targetSize = CGSize(width: 512, height: 512)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                  width: Int(targetSize.width),
                                  height: Int(targetSize.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: targetSize))

        let aspectWidth = targetSize.width / image.size.width
        let aspectHeight = targetSize.height / image.size.height
        let aspectRatio = min(aspectWidth, aspectHeight)
        let scaledWidth = image.size.width * aspectRatio
        let scaledHeight = image.size.height * aspectRatio
        let x = (targetSize.width - scaledWidth) / 2.0
        let y = (targetSize.height - scaledHeight) / 2.0
        let drawRect = CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight)

        context.draw(cgImage, in: drawRect)

        guard let outputCGImage = context.makeImage() else { return nil }
        return NSImage(cgImage: outputCGImage, size: targetSize)
    }
    
    func presentVideoCropper(for url: URL, completion: @escaping (URL?) -> Void) {
        if #available(macOS 12.0, *) {
            // Assume VideoCropperView exists
            let cropperView = VideoCropperView(videoURL: url, onComplete: { [weak self] processedURL in
                self?.cropperWindow?.close()
                self?.cropperWindow = nil
                completion(processedURL)
            }, onCancel: { [weak self] in
                self?.cropperWindow?.close()
                self?.cropperWindow = nil
                completion(nil)
            })
            
            let hostingController = NSHostingController(rootView: cropperView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "请裁切视频以保证1:1显示"
            window.setContentSize(NSSize(width: 420, height: 0))
            window.styleMask = [.titled, .closable]
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.cropperWindow = window // Assign to the property
        } else {
            print("视频裁剪功能需要 macOS 12.0 或更高版本。")
            completion(nil)
        }
    }
    
    func processVideo(_ fileURL: URL) -> URL? {
        let asset = AVAsset(url: fileURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return nil }
        
        let semaphore = DispatchSemaphore(value: 0)
        var outputURL: URL? = nil
        var exportError: Error? = nil

        Task {
            do {
                 outputURL = try await exportVideo(asset: asset, videoTrack: videoTrack)
             } catch {
                 exportError = error
             }
             semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 60)

        if let error = exportError {
            print("视频处理失败: \(error.localizedDescription)")
             if let url = outputURL { try? FileManager.default.removeItem(at: url) }
             outputURL = nil
        } else if outputURL != nil {
            print("视频处理成功: \(outputURL!.lastPathComponent)")
        } else {
             print("视频处理未完成或状态未知。")
        }
        
        return outputURL
    }
    
    private func exportVideo(asset: AVAsset, videoTrack: AVAssetTrack) async throws -> URL {
        let targetSize = CGSize(width: 512, height: 512)
        let originalSize = videoTrack.naturalSize
        let scale = min(targetSize.width / originalSize.width, targetSize.height / originalSize.height)
        let scaledWidth = originalSize.width * scale
        let scaledHeight = originalSize.height * scale
        let tx = (targetSize.width - scaledWidth) / 2.0
        let ty = (targetSize.height - scaledHeight) / 2.0
        
        var transform = CGAffineTransform.identity
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: tx / scale, y: ty / scale)

        let mixComposition = AVMutableComposition()
        guard let compositionVideoTrack = mixComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
             throw NSError(domain: "VideoProcessing", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建视频合成轨道"])
        }
        try compositionVideoTrack.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)

        if let audioTrack = asset.tracks(withMediaType: .audio).first,
           let compositionAudioTrack = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compositionAudioTrack.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
        }

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        
        let mainInstruction = AVMutableVideoCompositionInstruction()
        mainInstruction.timeRange = CMTimeRangeMake(start: .zero, duration: asset.duration)
        mainInstruction.layerInstructions = [layerInstruction]
        
        let mainComposition = AVMutableVideoComposition()
        mainComposition.instructions = [mainInstruction]
        mainComposition.frameDuration = CMTimeMake(value: 1, timescale: 30)
        mainComposition.renderSize = targetSize
        
        let backgroundLayer = CALayer()
        backgroundLayer.frame = CGRect(origin: .zero, size: targetSize)
        backgroundLayer.backgroundColor = NSColor.black.cgColor
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: targetSize)
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: targetSize)
        parentLayer.addSublayer(backgroundLayer)
        parentLayer.addSublayer(videoLayer)
        mainComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parentLayer)

        guard let exporter = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "VideoProcessing", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建导出 Session"])
        }
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        exporter.outputURL = tempURL
        exporter.outputFileType = .mp4
        exporter.videoComposition = mainComposition
        exporter.shouldOptimizeForNetworkUse = true
        
        await exporter.export()

        switch exporter.status {
        case .completed: return tempURL
        case .failed: throw exporter.error ?? NSError(domain: "VideoProcessing", code: 3, userInfo: [NSLocalizedDescriptionKey: "导出失败，未知错误"])
        case .cancelled: throw NSError(domain: "VideoProcessing", code: 4, userInfo: [NSLocalizedDescriptionKey: "导出被取消"])
        default: throw NSError(domain: "VideoProcessing", code: 5, userInfo: [NSLocalizedDescriptionKey: "导出状态未知"])
        }
    }

    // Update menu item title for the currently uploaded file
    func updateCurrentFile(_ filename: String) {
        // Accessing main class property - ensure it's not private
        currentUploadedFile = filename 
        if let menu = statusItem?.menu { // Use optional chaining for statusItem
            DispatchQueue.main.async {
                 // Assuming item at index 3 is the file display item
                 if menu.items.count > 3 {
                      menu.item(at: 3)?.title = "当前文件：\(filename)"
                 }
            }
        }
    }
}

// Helper extension for NSImage to get PNG data
extension NSImage {
    func pngData() -> Data? {
        guard let tiffRepresentation = self.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else { return nil }
        return bitmapImage.representation(using: .png, properties: [:])
    }
} 