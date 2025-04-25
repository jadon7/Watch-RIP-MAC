import AppKit
import Foundation

extension StatusMenuController {

    // MARK: - ADB Device Management

    func menuWillOpen(_ menu: NSMenu) {
        print("菜单即将打开，手动触发 ADB 设备检查...")
        updateADBDeviceList()
        adbStatusMenuItem?.isHidden = true
    }
    
    func updateADBDeviceList() {
        if adbExecutablePath == nil {
            findADBPath { [weak self] path in
                self?.adbExecutablePath = path
                self?.checkADBDevices { _ in }
            }
        } else {
            checkADBDevices { _ in }
        }
    }
    
    func checkADBDevices(completion: @escaping ([String: String]) -> Void) {
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
    
    func findADBPath(completion: @escaping (String?) -> Void) {
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

                // Use weak self inside closure to avoid retain cycles if task handler captures self strongly
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.adbExecutablePath = systemPath ?? foundPath
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
                // Use weak self inside closure to avoid retain cycles if task handler captures self strongly
                 DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.adbExecutablePath = fallbackSystemPath ?? foundPath
                    completion(self.adbExecutablePath)
                 }
            }
        } else {
             // Use weak self inside closure to avoid retain cycles if task handler captures self strongly
             DispatchQueue.main.async { [weak self] in
                 guard let self = self else { return }
                 self.adbExecutablePath = foundPath
                 completion(foundPath)
             }
        }
    }
    
    func updateMenuWithADBDevices(_ devices: [String: String]) {
        guard let menu = self.statusItem.menu else { return }
        let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备")
        guard adbTitleIndex != -1 else {
             print("[updateMenuWithADBDevices] 错误：未找到 ADB 标题菜单项")
             return
         }

        let currentDeviceItems = menu.items.filter { $0.action == #selector(selectADBDevice(_:)) }
        let currentDeviceIDs = currentDeviceItems.compactMap { $0.representedObject as? String }.sorted()
        let newDeviceIDs = devices.keys.sorted()
        
        // 首先根据设备是否存在更新安装菜单项的可见性
        self.installWatchAppMenuItem?.isHidden = devices.isEmpty
        
        if currentDeviceIDs == newDeviceIDs {
            // 如果设备列表未改变，只需更新名称和选中状态
            if selectedADBDeviceID != nil && !devices.keys.contains(selectedADBDeviceID!) {
                 print("[updateMenuWithADBDevices] 之前选中的设备 '\(selectedADBDeviceID!)' 不再存在，重新选择第一个。")
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
            // self.installWatchAppMenuItem?.isHidden = devices.isEmpty // 已在开头处理
            return
        }
        
        // 设备列表已改变，重建菜单项
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
            // self.installWatchAppMenuItem?.isHidden = true // 已在开头处理
            updateInstallMenuItemTitle(hasUpdateAvailable: false) // 确保无设备时标题正确
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
            // self.installWatchAppMenuItem?.isHidden = false // 已在开头处理
            // 在设备列表改变后，触发一次所有设备的版本检查以更新菜单标题
            checkAllDeviceVersionsAndUpdateMenu()
        }
        self.adbDevices = devices
    }
    
    @objc func selectADBDevice(_ sender: NSMenuItem) {
        guard let newlySelectedID = sender.representedObject as? String else { return }

        if let menu = statusItem.menu {
            let adbTitleIndex = menu.indexOfItem(withTitle: "ADB 设备")
            if adbTitleIndex != -1 {
                var loopIndex = adbTitleIndex + 1
                while let item = menu.item(at: loopIndex), item !== adbStatusMenuItem, !item.isSeparatorItem {
                    item.state = NSControl.StateValue.off
                    loopIndex += 1
                }
            }
        }
        selectedADBDeviceID = newlySelectedID
        sender.state = .on
        print("Selected ADB device: \(selectedADBDeviceID!)")
    }
    
    func runADBCommand(adbPath: String, arguments: [String], completion: ((Bool, String) -> Void)? = nil) {
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
    
    // MARK: - ADB File Operations

    // New method to push file to a specific directory without extra operations
    func pushFileToDirectory(adbPath: String, deviceId: String, localFilePath: String, remoteDirectory: String, remoteFileName: String, completion: @escaping (Bool, String) -> Void) {
        let remoteFilePath = "\(remoteDirectory)/\(remoteFileName)" // Construct full path

        print("开始推送文件 '\(localFilePath)' 到设备 '\(deviceId)' 的 '\(remoteFilePath)'")
        updateADBStatus("正在推送 \(remoteFileName)...", isError: false)

        // Ensure target directory exists (use '-p' to create parent dirs if needed)
        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "mkdir", "-p", remoteDirectory]) { [weak self] successMkdir, outputMkdir in
            guard let self = self else {
                completion(false, "控制器实例丢失")
                return
            }
            
            if successMkdir {
                print("目标目录 '\(remoteDirectory)' 确认存在或已创建。")
                // Push the file
                self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "push", localFilePath, remoteFilePath]) { successPush, outputPush in
                    if successPush {
                        print("文件 '\(remoteFileName)' 推送成功到 '\(remoteFilePath)'")
                        // Run sync command after successful push
                        self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "sync"]) { successSync, outputSync in
                            if successSync {
                                print("同步命令在设备 '\(deviceId)' 上成功执行。")
                                self.updateADBStatus("推送 \(remoteFileName) 成功", isError: false)
                                completion(true, "推送成功")
                            } else {
                                print("错误：同步命令在设备 '\(deviceId)' 上失败: \(outputSync)")
                                self.updateADBStatus("推送成功但同步失败", isError: true)
                                completion(false, "同步失败: \(outputSync)")
                            }
                        }
                    } else {
                        print("错误：推送文件 '\(remoteFileName)' 失败: \(outputPush)")
                        self.updateADBStatus("推送 \(remoteFileName) 失败", isError: true)
                        completion(false, "推送失败: \(outputPush)")
                    }
                }
            } else {
                print("错误：无法创建目标目录 '\(remoteDirectory)': \(outputMkdir)")
                self.updateADBStatus("创建目录失败", isError: true)
                completion(false, "创建目录失败: \(outputMkdir)")
            }
        }
    }

    // Original method for pushing files to the app's data directory and triggering actions
    func pushFileToDevice(adbPath: String, deviceId: String, localFilePath: String, remoteFileName: String) {
        // Use the constant for package name to build the remote directory path
        let remoteDir = "/storage/emulated/0/Android/data/\(wearAppPackageName)/files"
        let remoteFilePath = "\(remoteDir)/\(remoteFileName)"

        updateADBStatus("正在推送至 \(deviceId)...", isError: false)

        runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "mkdir", "-p", remoteDir]) { [weak self] successMkdir, _ in
            guard let self = self else { return }
            
            if successMkdir {
                self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "rm", "-f", "\(remoteDir)/*"]) { [weak self] successClear, _ in
                    guard let self = self else { return }
                    
                    self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "push", localFilePath, remoteFilePath]) { successPush, outputPush in
                        if successPush {
                            // --- Execute sync command AFTER successful push ---
                            print("Push reported success, executing sync command on device \(deviceId)...")
                            self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "sync"]) { successSync, outputSync in
                                if successSync {
                                    print("Sync command completed successfully.")
                                    // --- Now proceed with the rest AFTER sync ---
                                    self.updateADBStatus("推送成功!", isError: false) // Update status after sync

                                    // Check foreground app
                                    let expectedPackagePrefix = " \(wearAppPackageName)/" // Check for package name + slash
                                    print("Checking foreground app on device \(deviceId), looking for prefix: '\(expectedPackagePrefix)'")
                                    self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "dumpsys", "window", "|", "grep", "mCurrentFocus"]) { successCheckFocus, outputCheckFocus in

                                        var needsToStartApp = true
                                        if successCheckFocus && outputCheckFocus.contains(expectedPackagePrefix) {
                                            print("App package \(wearAppPackageName) seems to be in the foreground.")
                                            needsToStartApp = false
                                        } else if !successCheckFocus {
                                             print("Failed to check foreground app: \(outputCheckFocus). Assuming app needs to start.")
                                        } else {
                                             print("App package \(wearAppPackageName) not found in foreground focus: \(outputCheckFocus)")
                                        }

                                        // Conditionally start the app
                                        if needsToStartApp {
                                            let mainActivity = ".presentation.MainActivity" // Make sure this is correct
                                            let componentNameToStart = "\(wearAppPackageName)/\(mainActivity)"
                                            print("Attempting to start app: \(componentNameToStart) on device \(deviceId)")
                                            self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "am", "start", "-n", componentNameToStart]) { successStart, outputStart in
                                                if successStart {
                                                    print("App start command sent successfully. Starting poll for foreground status...")
                                                    // Start polling AFTER start command success
                                                    // Pass fileName to the polling function now
                                                    self.pollForAppForeground(adbPath: adbPath, deviceId: deviceId, targetPackagePrefix: expectedPackagePrefix, fileName: remoteFileName, maxAttempts: 25, delay: 0.2) { foregroundDetected in
                                                        // Broadcast is now sent INSIDE pollForAppForeground
                                                        if foregroundDetected {
                                                            print("Polling successful: App detected in foreground.")
                                                        } else {
                                                             print("Polling timed out: App not detected in foreground.")
                                                        }
                                                        // No need to send broadcast here anymore
                                                    }
                                                } else {
                                                     print("Failed to send app start command: \(outputStart). Skipping broadcast.")
                                                     // Maybe update status? self.updateADBStatus("启动 App 失败", isError: true)
                                                }
                                            }
                                        } else {
                                             // App already foreground, proceed directly to broadcast
                                             self.sendOpenFileBroadcast(adbPath: adbPath, deviceId: deviceId, fileName: remoteFileName)
                                        }
                                    }
                                    // --- End of logic after sync ---
                                } else {
                                    print("Sync command failed on device \(deviceId): \(outputSync)")
                                    self.updateADBStatus("推送成功，但同步失败", isError: true)
                                }
                            }
                            // --- End of sync command execution ---
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
    
    func updateADBStatus(_ message: String, isError: Bool) {
        guard let statusItem = adbStatusMenuItem else { return }
        
        DispatchQueue.main.async {
            statusItem.title = message
            if isError {
                statusItem.attributedTitle = NSAttributedString(
                    string: message,
                    attributes: [.foregroundColor: NSColor.systemRed]
                )
            } else {
                statusItem.attributedTitle = nil
                statusItem.title = message
            }
            
            // 显示状态项
            statusItem.isHidden = false
            
            // 5秒后自动隐藏（除非是错误）
            if !isError {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak statusItem] in
                    guard let statusItem = statusItem, !statusItem.isHidden else { return }
                    // 如果5秒后标题没变，才隐藏（避免新消息被错误隐藏）
                    if statusItem.title == message {
                        statusItem.isHidden = true
                    }
                }
            } else {
                // 错误状态保持显示稍长时间
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak statusItem] in
                    guard let statusItem = statusItem, !statusItem.isHidden else { return }
                    if statusItem.title == message {
                        statusItem.isHidden = true
                    }
                }
            }
        }
    }
    
    func updateMenuWithADBError(_ errorMessage: String) {
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

    func startADBCheckTimer() {
        print("启动 ADB 定时检查 (间隔 5 秒)")
        adbCheckTimer?.invalidate()

        // Make the timer run every 5 seconds, not 0.5
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            // Perform check in the background to avoid blocking main thread
            DispatchQueue.global(qos: .background).async {
                self?.checkADBDevices { devices in
                    // Log output already handled within checkADBDevices and updateMenu
                }
            }
        }
        self.adbCheckTimer = timer
        // Ensure timer is added to the main run loop for UI updates compatibility
        RunLoop.current.add(timer, forMode: .common)
    }

    // --- Helper function to poll for app foreground status ---
    // Now accepts fileName and sends broadcast internally
    func pollForAppForeground(adbPath: String, deviceId: String, targetPackagePrefix: String, fileName: String, maxAttempts: Int, delay: TimeInterval, completion: @escaping (Bool) -> Void) {
        var attempts = 0
        
        func check() {
            attempts += 1
            print("Polling attempt \(attempts)/\(maxAttempts) for foreground app: \(targetPackagePrefix)")
            self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "dumpsys", "window", "|", "grep", "mCurrentFocus"]) { success, output in
                // Log the result of this specific attempt in Chinese
                if success {
                    let detected = output.contains(targetPackagePrefix)
                    print("轮询尝试 \(attempts): 成功。检测到目标包 '\(targetPackagePrefix)': \(detected ? "是" : "否")。输出: \(output)")
                } else {
                     print("轮询尝试 \(attempts): 失败。错误: \(output)")
                }
                
                if success && output.contains(targetPackagePrefix) {
                    // App detected! Send broadcast immediately.
                    print("App detected in foreground on attempt \(attempts). Sending broadcast.")
                    self.sendOpenFileBroadcast(adbPath: adbPath, deviceId: deviceId, fileName: fileName)
                    completion(true) // Signal success and stop polling
                    return
                }
                
                if attempts >= maxAttempts {
                    // Timeout! Send broadcast as a fallback.
                    print("Polling timed out after \(attempts) attempts. Sending broadcast anyway.")
                    self.sendOpenFileBroadcast(adbPath: adbPath, deviceId: deviceId, fileName: fileName)
                    completion(false) // Signal timeout
                } else {
                    // Schedule next check
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        check()
                    }
                }
            }
        }
        
        // Start the first check
        check()
    }
    // --- End of polling helper function ---

    // --- Helper function to send broadcast ---
    func sendOpenFileBroadcast(adbPath: String, deviceId: String, fileName: String) {
        let broadcastAction = "\(wearAppPackageName).OPEN_FILE"
        let broadcastMessageKey = "message"
        let broadcastMessageValue = "openfile"
        print("Sending broadcast: Action = \(broadcastAction), Message Key = \(broadcastMessageKey), Message Value = \(broadcastMessageValue)")
        
        // Add the requested log message here
        print("我发送了一条广播，广播内容：\(fileName)")
        
        self.runADBCommand(adbPath: adbPath, arguments: ["-s", deviceId, "shell", "am", "broadcast", "-a", broadcastAction, "-p", wearAppPackageName, "--es", broadcastMessageKey, broadcastMessageValue]) { successBroadcast, outputBroadcast in
            if successBroadcast {
                 print("Broadcast sent successfully.")
            } else {
                 print("Failed to send broadcast: \(outputBroadcast)")
                 // Update status to indicate broadcast failure?
                 // self.updateADBStatus("推送成功，但广播失败", isError: true)
            }
        }
    }
    // --- End of helper function ---
} 