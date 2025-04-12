# Watch RIP MAC

macOS 端工具，用于将 Rive 文件或图片/视频推送到配对的 Wear OS 手表进行预览。支持通过本地 Wi-Fi 服务器或 ADB 进行文件传输。

## 功能

*   通过状态栏菜单操作。
*   启动本地 HTTP 服务器 (端口 8080) 共享文件。
*   支持上传单个 Rive 文件 (`.riv`/`.rive`)。
*   支持上传单个或多个图片/视频文件（自动处理为 512x512，图片为 PNG，视频为 MP4，并打包为 zip）。
*   通过 WebSocket (`/ws`) 实现客户端更新通知。
*   支持通过 ADB 将文件推送到连接的 Wear OS 设备的应用专用目录 (`/storage/emulated/0/Android/data/com.example.watchview/files/`)。
    *   自动检测连接的 ADB 设备。
    *   状态栏菜单提供设备单选功能。
    *   推送前自动清空目标目录。
*   集成 Sparkle 实现应用内自动更新检查和手动检查更新。

## 更新发布流程 (使用 Sparkle 和 GitHub Releases)

本应用使用 Sparkle 框架通过 GitHub Releases 进行更新。由于没有苹果开发者签名，采用的是非签名更新方式。

**发布新版本步骤:**

1.  **更新应用版本号:**
    *   在 Xcode 项目中，打开 `watch rip/Info.plist` 文件。
    *   修改 `CFBundleShortVersionString` (例如: "1.0.1") 和 `CFBundleVersion` (例如: "2")。确保这两个值都比上一版本高。

2.  **构建应用:**
    *   在 Xcode 中，选择 `Product` -> `Archive`。
    *   等待构建完成，Xcode 会打开 Organizer 窗口。
    *   在 Organizer 中，选中刚刚生成的 Archive。
    *   点击右侧的 "Distribute App" 按钮。
    *   选择 "Copy App" 作为分发方式。
    *   选择一个导出位置。Xcode 会将 `.app` 文件导出到你指定的位置。

3.  **打包应用:**
    *   找到导出的 `.app` 文件 (例如 `Watch RIP.app`)。
    *   将其压缩为 `.zip` 文件。**命名规则很重要**：通常使用 `AppName-Version.zip` 的格式，例如 `Watch-RIP-1.0.1.zip`。确保这个文件名与你将在 `appcast.xml` 中使用的文件名一致。

4.  **创建 GitHub Release:**
    *   访问你的 GitHub 仓库页面: `https://github.com/jadon7/Watch-RIP-MAC`。
    *   点击 "Releases" -> "Create a new release" (或 "Draft a new release")。
    *   **Tag version:** 输入与你的版本号对应的 Git 标签，例如 `v1.0.1`。**确保这个标签存在于你的 Git 历史中** (通常在你准备发布前打上 tag: `git tag v1.0.1 && git push origin v1.0.1`)。
    *   **Release title:** 输入版本标题，例如 `版本 1.0.1`。
    *   **Describe this release:** 编写版本更新日志或说明。
    *   **Attach binaries:** 将你上一步创建的 `.zip` 文件（例如 `Watch-RIP-1.0.1.zip`）拖拽或上传到这里。
    *   点击 "Publish release"。

5.  **更新 `appcast.xml`:**
    *   在你的本地仓库中，打开项目根目录下的 `appcast.xml` 文件。
    *   **在 `<channel>` 标签内，添加一个新的 `<item>` 块**，放在所有旧 `<item>` 块的**最上方**。
    *   **填充新 `<item>` 的信息:**
        *   `<title>`: 你的版本标题 (例如 `版本 1.0.1`)。
        *   `<sparkle:releaseNotesLink>`: 指向你刚刚创建的 GitHub Release 页面的 URL (例如 `https://github.com/jadon7/Watch-RIP-MAC/releases/tag/v1.0.1`)。
        *   `<pubDate>`: 当前的发布日期和时间 (遵循 RFC 822 格式，例如 `Sun, 17 Mar 2024 12:00:00 +0800`)。
        *   `<enclosure>`:
            *   `url`: 指向你在 GitHub Release 中上传的 `.zip` 文件的**下载链接** (例如 `https://github.com/jadon7/Watch-RIP-MAC/releases/download/v1.0.1/Watch-RIP-1.0.1.zip`)。**确保这个链接正确！**
            *   `sparkle:version`: 对应 `Info.plist` 中的 `CFBundleVersion` (例如 `2`)。
            *   `sparkle:shortVersionString`: 对应 `Info.plist` 中的 `CFBundleShortVersionString` (例如 `1.0.1`)。
            *   `length`: `.zip` 文件的**精确大小** (以字节 Bytes 为单位)。你可以通过 Finder 的"显示简介"或 `ls -l` 命令获取。**这个值必须准确！**
        *   `<sparkle:minimumSystemVersion>`: (可选) 应用所需的最低 macOS 版本。
    *   **保存 `appcast.xml` 文件。**

6.  **提交并推送 `appcast.xml`:**
    *   将修改后的 `appcast.xml` 文件提交到你的 Git 仓库。
    *   `git add appcast.xml`
    *   `git commit -m "更新 appcast.xml 至版本 1.0.1"`
    *   `git push origin main` (同时也会推送到 GitHub)

**完成！** 现在，当用户运行旧版本的 Watch RIP 时，Sparkle 会自动（或手动）检查 `https://raw.githubusercontent.com/jadon7/Watch-RIP-MAC/main/appcast.xml`，发现新的版本信息，并提示用户下载和安装你在 GitHub Release 中提供的 `.zip` 文件。

## 注意事项

*   **版本号一致性**: 确保 `Info.plist` 中的版本号 (`CFBundleShortVersionString`, `CFBundleVersion`) 与 `appcast.xml` 中对应 `<item>` 的版本号 (`sparkle:shortVersionString`, `sparkle:version`) 以及 GitHub Release 的 Tag 和 `.zip` 文件名保持逻辑一致。
*   **下载链接和文件大小**: `appcast.xml` 中的 `enclosure url` 和 `length` 必须准确无误，否则更新会失败。
*   **Appcast URL**: `Info.plist` 中的 `SUFeedURL` 和 `appcast.xml` 中的 `<link>` 标签都应指向 `appcast.xml` 在 GitHub 上的 Raw URL。
*   **签名 (可选但推荐)**: 为了提高安全性，可以考虑对你的应用更新进行 EdDSA 签名。这需要生成密钥对，并将公钥添加到 `Info.plist` (`SUPublicEDKey`)，在生成 `.zip` 文件后对其签名，并将签名添加到 `appcast.xml` (`sparkle:edSignature`)。具体步骤请参考 Sparkle 文档。

-   [x] 处理 IP 地址的显示 BUG
-   [x] 在状态菜单显示功能
-   [x] 添加 ADB 设备检测
<!-- -   [x] 添加 ADB 文件传输能力 -->