import SwiftUI
import AppKit
import Foundation // For URLSession, etc.

extension StatusMenuController {

    // MARK: - Wear OS App Install/Update Logic

    @objc func installOrUpdateWatchApp(_ sender: NSMenuItem) {
        print("用户点击安装/更新，直接启动更新流程窗口...")
        
        // Close existing window if any
        if let existingController = self.watchAppUpdateWindowController {
            print("发现已存在的更新窗口，正在关闭...")
            existingController.closeWindow(success: false)
        }
        
        // Get current device and ADB path
        guard let deviceId = selectedADBDeviceID, let adbPath = adbExecutablePath else {
            let alert = NSAlert()
            alert.messageText = "无法开始更新"
            alert.informativeText = "请先连接并选择一个设备。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
            return
        }
        
        // Create and show update window
        let windowController = WatchAppUpdateWindowController(
            deviceId: deviceId, 
            adbPath: adbPath,
            completionHandler: { [weak self] success in
                print("手表App更新流程 \(success ? "完成" : "取消")")
                self?.watchAppUpdateWindowController = nil
                self?.checkAllDeviceVersionsAndUpdateMenu() // Refresh menu title after flow
            },
            onInstall: { [weak self] in
                self?.startDownloadAndInstallProcess()
            },
            onCancel: { [weak self] in
                self?.cancelCurrentDownload()
            }
        )
        
        self.watchAppUpdateWindowController = windowController
        windowController.showWindow(nil)
        
        // Start the check process for the window
        self.checkDeviceVersionAndProceedForWindow(deviceId: deviceId, adbPath: adbPath)
    }
    
    // Check device version and then fetch online info for the update window
    func checkDeviceVersionAndProceedForWindow(deviceId: String, adbPath: String) {
        self.updateWindowStatus(.checking)
        getDeviceAppVersion(deviceId: deviceId, adbPath: adbPath) { [weak self] deviceVersion in
            guard let self = self else { return }
            self.fetchOnlineVersionForWindow(deviceVersion: deviceVersion, deviceId: deviceId, adbPath: adbPath)
        }
    }

    // Fetch online version specifically for the update window flow
    func fetchOnlineVersionForWindow(deviceVersion: String?, deviceId: String, adbPath: String) {
        let appcastURLString = "https://raw.githubusercontent.com/jadon7/Watch-RIP-WearOS/refs/heads/main/appcast.xml"
        guard let url = URL(string: appcastURLString) else {
            DispatchQueue.main.async { self.updateWindowStatus(.error(message: "无效的Appcast URL")) }
            return
        }
        
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            
            guard error == nil, let data = data else {
                 DispatchQueue.main.async {
                     self.updateWindowStatus(.error(message: "获取更新信息失败: \(error?.localizedDescription ?? "无数据")"))
                 }
                 return
             }
            
            let parser = XMLParser(data: data)
            let delegate = WearOSAppcastParserDelegate() // Assumes this class is accessible
            parser.delegate = delegate
            
            if parser.parse(), let onlineVersion = delegate.latestVersionName,
               let downloadURL = delegate.downloadURL, let downloadLengthStr = delegate.length,
               let downloadLength = Int64(downloadLengthStr) {
                
                let sizeInMB = self.formatFileSize(sizeInBytes: downloadLength)
                
                // Store info needed for download/install
                self.pendingInstallInfo = (
                    onlineVersion: onlineVersion,
                    downloadURL: downloadURL,
                    downloadLength: downloadLength,
                    deviceId: deviceId,
                    adbPath: adbPath
                )
                
                // Update window status based on version comparison
                DispatchQueue.main.async {
                     if let devVersion = deviceVersion {
                         switch devVersion.compare(onlineVersion, options: .numeric) {
                         case .orderedSame, .orderedDescending:
                             self.updateWindowStatus(.noUpdateNeeded)
                         case .orderedAscending:
                             self.updateWindowStatus(.available(version: onlineVersion, downloadSize: sizeInMB))
                         }
                     } else {
                         self.updateWindowStatus(.available(version: onlineVersion, downloadSize: sizeInMB))
                     }
                 }
            } else {
                DispatchQueue.main.async { self.updateWindowStatus(.error(message: "解析更新信息失败")) }
            }
        }
        task.resume()
    }
    
    // Update the status of the update window
    func updateWindowStatus(_ status: WatchAppUpdateStatus) {
        DispatchQueue.main.async {
            self.watchAppUpdateWindowController?.updateStatus(to: status)
        }
    }
    
    // Start download/install process when user clicks "Install" in the window
    func startDownloadAndInstallProcess() {
        guard let info = pendingInstallInfo else {
            updateWindowStatus(.error(message: "丢失版本信息"))
            return
        }
        guard let url = URL(string: info.downloadURL) else {
            updateWindowStatus(.error(message: "无效的下载URL"))
            return
        }
        guard let cacheDir = getAPKCacheDirectory() else { return } // Use helper

        // Construct the expected destination path for the current version
        let apkFileName = "watch_view_\(info.onlineVersion).apk"
        let destinationURL = cacheDir.appendingPathComponent(apkFileName)

        // Check if the target version APK already exists in the cache
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            print("找到最新版本的缓存 APK: \(destinationURL.path)")
            updateWindowStatus(.installing) // Indicate installation start
            // Directly install from cache
            installAPKFromLocalPath(apkPath: destinationURL.path, deviceId: info.deviceId, adbPath: info.adbPath)
            
            // Optional: Clean up OLDER versions after successful install later?
            // For now, we just install the cached version.
            
        } else {
            print("未找到版本 \(info.onlineVersion) 的缓存 APK，需要下载。")
            
            // Clear cache directory NOW, before starting download
            clearAPKCacheDirectory(cacheDir: cacheDir)
            
            print("开始下载新的 APK 到: \(destinationURL.path)")
            // Start the download process
            startDownloadAPK(url: url, destination: destinationURL, deviceId: info.deviceId, adbPath: info.adbPath)
        }
    }
    
    // Helper to get cache directory URL
    private func getAPKCacheDirectory() -> URL? {
         guard let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            updateWindowStatus(.error(message: "无法访问缓存目录"))
            return nil
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.jadon7.watchrip"
        let cacheDir = appSupportDir.appendingPathComponent(bundleId).appendingPathComponent("APKCache")
        
        do {
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
            return cacheDir
        } catch {
            print("创建缓存目录失败: \(error.localizedDescription)")
            updateWindowStatus(.error(message: "创建缓存目录失败"))
            return nil
        }
    }
    
    // Helper to clear cache directory
    private func clearAPKCacheDirectory(cacheDir: URL) {
         print("正在清空历史 APK 缓存目录: \(cacheDir.path)")
        do {
            let cachedFiles = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil, options: [])
            for fileURL in cachedFiles where !fileURL.hasDirectoryPath {
                 try FileManager.default.removeItem(at: fileURL)
                 print("已删除历史 APK: \(fileURL.lastPathComponent)")
            }
             print("APK 缓存目录已清空。")
        } catch {
            print("清空 APK 缓存目录失败: \(error.localizedDescription)")
            // Optionally update status or decide if this error is critical
        }
    }

    // Start the APK download task
    func startDownloadAPK(url: URL, destination: URL, deviceId: String, adbPath: String) {
        updateWindowStatus(.downloading(progress: 0.0))
        let expectedLength = pendingInstallInfo?.downloadLength ?? 0
        let task = urlSession.downloadTask(with: url)
        currentDownloadTask = task
        apkDownloadInfo = (version: "unknown", url: url, length: expectedLength, destination: destination)
        downloadCompletionInfo = (deviceId: deviceId, adbPath: adbPath)
        task.resume()
    }
    
    // Install APK from a local path
    func installAPKFromLocalPath(apkPath: String, deviceId: String, adbPath: String) {
        updateWindowStatus(.installing)
        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "install", "-r", apkPath]) { [weak self] success, output in
             guard let self = self else { return }
            if success && output.lowercased().contains("success") {
                print("手表App安装成功!")
                self.updateWindowStatus(.installComplete)
            } else {
                print("手表App安装失败: \(output)")
                self.updateWindowStatus(.error(message: "安装失败: \(output)"))
            }
        }
    }
    
    // Cancel the current download task
    func cancelCurrentDownload() {
        print("用户请求取消下载...")
        currentDownloadTask?.cancel()
        currentDownloadTask = nil
        apkDownloadInfo = nil
        downloadCompletionInfo = nil
        // Optionally update window status to indicate cancellation
        // updateWindowStatus(.idle) or similar
    }
    
    // Format file size for display
    func formatFileSize(sizeInBytes: Int64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useMB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: sizeInBytes)
    }
    
    // MARK: - URLSessionDownloadDelegate Methods
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard downloadTask == currentDownloadTask else { return }
        let expectedLength = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (apkDownloadInfo?.length ?? 0)
        var progress: Double = 0
        if expectedLength > 0 {
            progress = Double(totalBytesWritten) / Double(expectedLength)
        }

        let now = Date()
        let progressInt = Int(progress * 100)
        if now.timeIntervalSince(lastProgressUpdate) > 0.2 || Int(lastReportedProgress * 100) != progressInt {
            updateWindowStatus(.downloading(progress: progress))
            lastProgressUpdate = now
            lastReportedProgress = progress
        }
    }
    
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        print("APK 下载完成，临时文件位于: \(location.path)")
        guard downloadTask == currentDownloadTask, let info = apkDownloadInfo else {
            print("下载完成但无法识别任务或缺少信息")
            return
        }
        
        let destinationURL = info.destination
        let fm = FileManager.default
        
        do {
            try? fm.removeItem(at: destinationURL) // Remove existing file first
            try fm.moveItem(at: location, to: destinationURL)
            print("APK 已移动到缓存目录: \(destinationURL.path)")
            
            currentDownloadTask = nil
            self.apkDownloadInfo = nil
            
            if let completionInfo = self.downloadCompletionInfo {
                installAPKFromLocalPath(apkPath: destinationURL.path, deviceId: completionInfo.deviceId, adbPath: completionInfo.adbPath)
            } else {
                updateWindowStatus(.error(message: "下载完成但丢失了设备信息"))
            }
        } catch {
            print("移动APK文件失败: \(error.localizedDescription)")
            updateWindowStatus(.error(message: "保存下载文件失败"))
        }
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
             // Check if the error is cancellation
             let nsError = error as NSError
             if !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) {
                 print("URLSession 任务出错: \(error.localizedDescription)")
                 if task == currentDownloadTask {
                     DispatchQueue.main.async { // Ensure UI updates on main thread
                          self.updateWindowStatus(.error(message: "下载失败: \(error.localizedDescription)"))
                     }
                 }
             } else {
                  print("下载任务被取消。")
                  // Update status to idle or cancelled if needed
                  // DispatchQueue.main.async { self.updateWindowStatus(.idle) }
             }
              // Clean up task info regardless of error type if it's the current task
             if task == currentDownloadTask {
                  currentDownloadTask = nil
                  apkDownloadInfo = nil
                  downloadCompletionInfo = nil
             }
        }
    }
    
    // MARK: - Background Version Check
    
    func startBackgroundOnlineVersionCheck() {
        checkOnlineVersionIfNeeded(triggeredByTimer: false)
        backgroundCheckTimer?.invalidate()
        backgroundCheckTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkOnlineVersionIfNeeded(triggeredByTimer: true)
        }
    }

    func checkOnlineVersionIfNeeded(triggeredByTimer: Bool) {
        let lastCheckDate = userDefaults.object(forKey: lastOnlineCheckDateKey) as? Date
        let twelveHoursAgo = Date().addingTimeInterval(-12 * 60 * 60) // Check every 12 hours
        
        if lastCheckDate == nil || lastCheckDate! < twelveHoursAgo {
            print("需要执行后台线上版本检查...")
            fetchLatestOnlineVersionInBackground()
        } else if triggeredByTimer {
             print("后台定时器触发，但上次检查在12小时内，跳过。")
        }
    }
    
    func fetchLatestOnlineVersionInBackground() {
        let appcastURLString = "https://raw.githubusercontent.com/jadon7/Watch-RIP-WearOS/refs/heads/main/appcast.xml"
        guard let url = URL(string: appcastURLString) else { return }
        
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, error == nil, let data = data else {
                print("后台获取线上版本失败: \(error?.localizedDescription ?? "无数据")")
                return
            }
            
            let parser = XMLParser(data: data)
            let delegate = WearOSAppcastParserDelegate()
            parser.delegate = delegate
            
            if parser.parse(), let onlineVersion = delegate.latestVersionName {
                print("后台获取到线上版本: \(onlineVersion)")
                let previousVersion = self.latestKnownOnlineVersion
                let needsUpdateCheck = (previousVersion != onlineVersion)
                
                self.userDefaults.set(onlineVersion, forKey: self.latestOnlineVersionKey)
                self.userDefaults.set(Date(), forKey: self.lastOnlineCheckDateKey)
                self.latestKnownOnlineVersion = onlineVersion
                
                if needsUpdateCheck || previousVersion == nil {
                    DispatchQueue.main.async {
                         self.checkAllDeviceVersionsAndUpdateMenu()
                    }
                }
            } else {
                print("后台解析线上版本失败")
            }
        }
        task.resume()
    }
    
    func checkAllDeviceVersionsAndUpdateMenu() {
        guard let adbPath = self.adbExecutablePath, !adbDevices.isEmpty else {
            DispatchQueue.main.async { self.updateInstallMenuItemTitle(hasUpdateAvailable: false) }
            return
        }
        guard let knownOnlineVersion = self.latestKnownOnlineVersion else {
             print("尚未获取到线上版本信息，无法比较。")
             DispatchQueue.main.async { self.updateInstallMenuItemTitle(hasUpdateAvailable: false) }
             return
        }

        var updateRequiredFlags = [String: Bool]() // Store result per device ID
        let group = DispatchGroup()
        let resultQueue = DispatchQueue(label: "com.jadon7.watchrip.updateresultqueue", attributes: .concurrent) // Concurrent for writes
        let checkQueue = DispatchQueue(label: "com.jadon7.watchrip.updatecheckqueue", attributes: .concurrent)

        print("开始检查所有连接设备的版本与线上版本 [\(knownOnlineVersion)] 的对比...")

        for deviceId in adbDevices.keys {
            group.enter()
            checkQueue.async {
                self.getDeviceAppVersion(deviceId: deviceId, adbPath: adbPath) { deviceVersion in
                     var needsUpdate = false
                     if let version = deviceVersion {
                         needsUpdate = (version.compare(knownOnlineVersion, options: .numeric) == .orderedAscending)
                         print("设备 [\(deviceId)] 版本 [\(version)] vs 线上 [\(knownOnlineVersion)]: 需要更新 = \(needsUpdate)")
                     } else {
                          print("设备 [\(deviceId)] 未安装或无法获取版本，视为需要更新。")
                          needsUpdate = true
                     }
                     // Safely update the dictionary
                     resultQueue.async(flags: .barrier) { // Use barrier for safe write
                         updateRequiredFlags[deviceId] = needsUpdate
                         group.leave()
                     }
                }
            }
        }

        group.notify(queue: .main) { // Process results on main thread
            let updateAvailableForAnyDevice = updateRequiredFlags.values.contains(true)
            print("所有设备版本检查完成。是否有任何设备需要更新: \(updateAvailableForAnyDevice)")
            self.updateInstallMenuItemTitle(hasUpdateAvailable: updateAvailableForAnyDevice)
        }
    }
    
    func getDeviceAppVersion(deviceId: String, adbPath: String, completion: @escaping (String?) -> Void) {
        // Use the constant for package name
        let command = "dumpsys package \(wearAppPackageName) | grep versionName"
        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", command]) { success, output in
            var deviceVersion: String? = nil
            if success, let range = output.range(of: "versionName=") {
                 let versionString = String(output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                 if !versionString.isEmpty && versionString.contains(".") { // Basic validation
                     deviceVersion = versionString
                 }
             }
            // Ensure completion is called on main thread if it updates UI
            DispatchQueue.main.async {
                 completion(deviceVersion)
            }
        }
    }
    
    func updateInstallMenuItemTitle(hasUpdateAvailable: Bool) {
        DispatchQueue.main.async {
             let baseTitle = "安装/更新手表 App"
             self.installWatchAppMenuItem?.title = hasUpdateAvailable ? "\(baseTitle) (有新版)" : baseTitle
             // Add visual cue like an emoji or color change if needed
             // self.installWatchAppMenuItem?.attributedTitle = ... for color
        }
    }
} 