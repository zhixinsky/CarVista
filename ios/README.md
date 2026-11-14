# CarCanvas 缓存诊断原型

当前已实现：用户选择目录、只读文件清单、基线对比、JSON 导出、错误域和错误码记录、扫描数量限制、不跟随符号链接。

尚未实现：系统容器访问后端、自动发现 CarPlayWallpaper、CPBitmap 编解码、壁纸写入和恢复。当前版本不能独立解决 iOS 27.2 的系统缓存访问问题，不应标注为已支持该功能。

## 构建

需要 macOS、Xcode 和 XcodeGen。在本目录运行 `xcodegen generate`，打开生成的 `CarCanvasDiagnostics.xcodeproj`，选择开发团队和设备后构建。当前原型不需要 App Group；未来后端若要求该权限，必须同时配置 entitlement 和有效 provisioning profile。

## 测试

可先用 Files 内的测试文件夹：记录基线，再新增、修改、移除测试文件，重新扫描，检查报告变化。文件内容未变但时间改变也会被标记；同尺寸同修改时间的内容变化不会被发现。

真实缓存调查应比较切换车机内置壁纸前后的目录副本。只有获取了有效访问权限才能收集系统目录；Files 选择器不能凭空获得该权限。对比不完整扫描时，未再扫描到的文件不能被认定为删除。

## 已有静态证据

原 IPA SHA-256：`45D58DFDE462C41144813518944263AA51BE93F8958DC92C863EC9771A99E895`。

二进制 `Payload/AirWall.app/AirWall` 包含 `com.apple.CarPlayWallpaper`、`Library/Caches/MappedImageCache/com.apple.CarPlayApp.wallpaper-images`、`container_query_create`、`writeToCPBitmapFile:flags:` 和 `_CPBitmapCreateImagesFromData`。这些字符串不能证明 iOS 27.2 上路径或接口有效。

当前 Windows 环境没有 Swift/Xcode，尚未编译或真机测试。

## GitHub 云构建

仓库包含手动触发的 `.github/workflows/ios-diagnostics.yml`。上传到自己可管理的 GitHub 仓库后，在 Actions 运行 `Build diagnostic IPA (unsigned)`，成功后下载同名构建产物。工作流在 macOS 上构建真机 arm64 应用并打包未签名 IPA；没有安装签名，需要另行签名才能安装。目前未执行云构建，不能保证首次编译成功。

此产物仍是目录扫描原型，不具备系统容器访问能力，不能据此验收 CarPlay 缓存定位或壁纸修改。真正的车机测试包必须在实现访问后端后再构建。
