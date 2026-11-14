# CarCanvas Workshop 0.2

面向自有 iPhone 的 CarPlay 自定义壁纸实验版本。当前已实现完整操作流程，但 iOS 27.2 / iPhone 16 Pro Max / 真实车机效果尚未验证；不能将编译通过等同于设备兼容性通过。

## 功能

- 基于 WQFiles / worse_query 的 App Group 访问后端，快速定位和可停止的完整容器扫描。
- 仅识别 `com.apple.CarPlayWallpaper`，在其 Library/Caches 下发现实际 CPBitmap，不写死颜色或 `-14` 后缀。
- 读取目标尺寸、深浅色分类；解码失败或尺寸异常时禁止替换。
- 相册选图、等比缩放、横纵裁剪位置预览；生成并回读验证 CPBitmap。
- 持久化壁纸历史与 CPBitmap 导出；深浅色分别选择目标，也可将相同尺寸的历史图片用于另一目标。
- 写入前备份，原位写入并回读校验；拒绝扫描后已变化的目标；备份历史恢复。
- 诊断报告导出。若访问或格式不兼容，会明确失败，不假装成功。

## 安装与测试

GitHub Actions 产物为 `CarCanvasWorkshop-resign.ipa`。它带有 ad-hoc 签名和 App Group entitlement，**不能直接安装**，必须通过签名工具授予有效 App Group 并重新签名。AltStore / SideStore 等支持 App Group 的流程可作为选择；仅保留 entitlement 文本不代表具备权限。普通企业通配符 profile 通常不满足条件。

1. 签名安装后，在说明页确认 App Group 不为空。
2. 停车后连接 CarPlay，切换几张内置图片壁纸生成缓存。
3. 回到应用先快速扫描；未找到时再完整扫描，保持前台，可能需要数分钟。
4. 选择一个可解码的深色或浅色目标，选图裁剪，生成并保存，再确认备份和替换。
5. 重启 iPhone 并连接车机观察。应用无法自行确认车机显示结果。
6. 如需还原，扫描确认容器后在恢复页选备份，恢复后重启验证。

系统容器访问受版本、签名和权限影响。若缓存格式已不再是 CPBitmap，此版本会报告未找到可识别文件，不会修改未知格式。不要卸载应用来“恢复壁纸”：卸载会删除本应用内备份，而系统缓存修改可能仍然保留。

## 构建

macOS + Xcode + XcodeGen：在 ios 目录执行 `xcodegen generate`，打开 `CarCanvasWorkshop.xcodeproj`。本地真机签名需为自己的 Bundle ID 创建并授予 App Group。

`.github/workflows/ios-diagnostics.yml` 在 main 更新后自动编译。流水线先运行裁剪/扫描测试和上游文件写入与容器解析回归测试，再编译真机 arm64 应用，打包并生成 SHA-256。

## 测试边界

主机测试覆盖裁剪覆盖范围、比例保持、文件变化比较、符号链接排除、缺失目录错误，以及上游备份/写入/恢复/解析回归。这些测试不会修改手机系统容器。

尚须真机验证：实际签名权限、令牌获取、容器识别、私有 CPBitmap API 的当前行为、断电情形和车机加载结果。原位写入保留 inode，但不能保证面对突然断电或系统并发写入时完全原子化。

## 开源许可

新应用代码采用 GPL-3.0-or-later，许可证随应用打包。WQFiles 模块保留原始版权及许可证，版本和来源见 Vendor/NOTICE.md。对应源码：https://github.com/zhixinsky/car 。

仓库 `build/CarCanvas-MobileHouseArrest.ipa` 是原作者旧版产物，**不是**本工程构建结果，也没有被修改或重新分发到新应用包内。
