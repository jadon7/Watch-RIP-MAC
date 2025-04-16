import AppKit
import Sparkle

extension StatusMenuController {

    // MARK: - Sparkle App Update Check

    @objc func checkForUpdatesMenuItemAction(_ sender: NSMenuItem) {
        updater.checkForUpdates(nil)
    }
    
    func updateCheckUpdatesMenuItemTitle(hasUpdate: Bool) {
        DispatchQueue.main.async {
            self.checkUpdatesMenuItem?.title = hasUpdate ? "新版本可用! 点击更新" : "检查更新..."
        }
    }
} 