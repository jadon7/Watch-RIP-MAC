import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension StatusMenuController {

    // MARK: - P2 File Upload

    @objc func uploadFilesToP2(_ sender: Any?) {
        guard let deviceId = selectedADBDeviceID, let adbPath = adbExecutablePath else {
            updateADBStatus("未选择ADB设备或未找到ADB路径", isError: true)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        // panel.allowedContentTypes = [UTType.image] // 可以取消注释以仅允许图片

        // 激活应用以将面板置于最前
        NSApplication.shared.activate(ignoringOtherApps: true)

        panel.begin { [weak self] result in
            guard let self = self, result == .OK else { return }
            let files = panel.urls
            self.pushFilesSequentially(files: files, index: 0, deviceId: deviceId, adbPath: adbPath)
        }
    }

    private func pushFilesSequentially(files: [URL], index: Int, deviceId: String, adbPath: String) {
        guard index < files.count else {
            // 所有文件处理完毕
            print("所有 P2 文件推送完成。")
            self.updateADBStatus("\(files.count) 个文件推送完成", isError: false)
            return
        }

        let fileURL = files[index]
        let localFilePath = fileURL.path
        let remoteFileName = fileURL.lastPathComponent
        let remoteDirectory = "/sdcard/Download" // P2 目标目录

        // 更新状态，显示当前正在推送的文件
        self.updateADBStatus("正在推送第 \(index + 1)/\(files.count) 个文件: \(remoteFileName)...", isError: false)

        // 调用新的推送方法
        pushFileToDirectory(adbPath: adbPath, deviceId: deviceId, localFilePath: localFilePath, remoteDirectory: remoteDirectory, remoteFileName: remoteFileName) { [weak self] success, message in
            guard let self = self else { return }
            if !success {
                print("推送文件 \(remoteFileName) 到 P2 失败: \(message)")
                // 可以在这里选择停止或继续推送下一个文件
                // 为了简单起见，我们继续推送下一个文件，但会记录错误
                self.updateADBStatus("推送 \(remoteFileName) 失败: \(message)", isError: true)
            }
            // 推送下一个文件，无论成功与否
            DispatchQueue.main.async {
                self.pushFilesSequentially(files: files, index: index + 1, deviceId: deviceId, adbPath: adbPath)
            }
        }
    }

} 