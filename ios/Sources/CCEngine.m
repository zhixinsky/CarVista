// SPDX-License-Identifier: GPL-3.0-or-later
#import "CCEngine.h"
#import "WQAccess.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/stat.h>

static NSString *const CCIdentifier = @"com.apple.CarPlayWallpaper";
static NSString *const CCParent = @"/private/var/mobile/Containers/Data/Application";
static BOOL CCAllowFullScan;
static NSMutableSet<NSString *> *CCRoots;
static WQScanCancellation *CCScan;
static BOOL CCConfirm(NSString *what, int64_t ids, double seconds) {
    wq_log(@"CarCanvas scan: %@, %lld ids, estimate %.0f seconds", what, ids, seconds);
    return CCAllowFullScan;
}
static void CCProgress(int64_t done, int64_t total, BOOL finished) {
    if (finished) wq_log(@"CarCanvas container scan finished: %lld/%lld", done, total);
}
static NSDictionary *CCFail(NSString *text) { return @{@"ok": @NO, @"message": text ?: @"操作失败"}; }
static NSString *CCCanonical(NSString *path) {
    NSString *p = path.stringByStandardizingPath;
    if ([p hasPrefix:@"/var/"]) p = [@"/private" stringByAppendingString:p];
    return p;
}
static void CCSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CCRoots = NSMutableSet.new;
        wq_set_container_label_resolver(wq_bundle_id_for_container);
        wq_set_container_list_provider(wq_ls_container_paths);
        wq_set_full_scan_ui(CCConfirm, CCProgress);
    });
}
static BOOL CCRegisterRoot(NSString *path) {
    NSString *p = CCCanonical(path);
    if (![p.stringByDeletingLastPathComponent isEqualToString:CCParent]) return NO;
    if (![[NSUUID alloc] initWithUUIDString:p.lastPathComponent]) return NO;
    if (![wq_container_label(p) isEqualToString:CCIdentifier]) return NO;
    @synchronized (CCRoots) { [CCRoots addObject:p]; }
    return YES;
}
static BOOL CCAllowed(NSString *path) {
    NSString *p = CCCanonical(path);
    if (![p.pathExtension.lowercaseString isEqualToString:@"cpbitmap"]) return NO;
    NSArray *roots;
    @synchronized (CCRoots) { roots = CCRoots.allObjects; }
    for (NSString *root in roots) {
        // Recheck identity on every mutation; never accept an arbitrary path.
        NSString *prefix = [[root stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingString:@"/"];
        if (![p hasPrefix:prefix] || ![wq_container_label(root) isEqualToString:CCIdentifier]) continue;
        NSString *cursor = p;
        while ([cursor hasPrefix:[root stringByAppendingString:@"/"]]) {
            struct stat st;
            if (!wq_stat(cursor, &st) || S_ISLNK(st.st_mode)) return NO;
            cursor = cursor.stringByDeletingLastPathComponent;
        }
        return YES;
    }
    return NO;
}
static UIImage *CCDecode(NSData *data) {
    if (!data.length) return nil;
    typedef CFArrayRef (*Decoder)(CFDataRef, void *, int, void *);
    static Decoder decode;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_LAZY);
        if (handle) {
            decode = (Decoder)dlsym(handle, "CPBitmapCreateImagesFromData");
            if (!decode) decode = (Decoder)dlsym(handle, "_CPBitmapCreateImagesFromData");
        }
        if (!decode) decode = (Decoder)dlsym(RTLD_DEFAULT, "CPBitmapCreateImagesFromData");
        if (!decode) decode = (Decoder)dlsym(RTLD_DEFAULT, "_CPBitmapCreateImagesFromData");
    });
    if (!decode) return nil;
    CFArrayRef array = decode((__bridge CFDataRef)data, NULL, 1, NULL);
    if (!array) return nil;
    UIImage *image = nil;
    if (CFGetTypeID(array) == CFArrayGetTypeID() && CFArrayGetCount(array)) {
        CFTypeRef first = CFArrayGetValueAtIndex(array, 0);
        if (first && CFGetTypeID(first) == CGImageGetTypeID()) image = [UIImage imageWithCGImage:(CGImageRef)first];
    }
    CFRelease(array);
    return image;
}
static NSArray *CCWalk(NSString *root, NSMutableArray *issues, WQScanCancellation *scan) {
    NSString *caches = [root stringByAppendingPathComponent:@"Library/Caches"];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:caches];
    NSMutableArray *files = NSMutableArray.new;
    NSUInteger count = 0;
    while (queue.count && count < 20000 && !scan.isCancelled) {
        @autoreleasepool {
        NSString *dir = queue.lastObject;
        [queue removeLastObject];
        NSString *error = nil;
        NSArray *names = wq_list(dir, &error);
        if (!names) { [issues addObject:[NSString stringWithFormat:@"%@: %@", dir, error ?: @"无法列出目录"]]; continue; }
        for (NSString *name in names) {
            if (scan.isCancelled) break;
            if (++count > 20000) break;
            if ([name isEqualToString:@"."] || [name isEqualToString:@".."] || [name containsString:@"/"]) continue;
            NSString *path = [dir stringByAppendingPathComponent:name];
            struct stat st;
            if (!wq_stat(path, &st)) { [issues addObject:[NSString stringWithFormat:@"无法检查 %@", path]]; continue; }
            if (S_ISLNK(st.st_mode)) continue;
            if (S_ISDIR(st.st_mode)) {
                if (path.pathComponents.count - caches.pathComponents.count < 10) [queue addObject:path];
                else [issues addObject:[NSString stringWithFormat:@"达到目录深度限制：%@", path]];
            } else if (S_ISREG(st.st_mode) && [name.pathExtension.lowercaseString isEqualToString:@"cpbitmap"]) {
                @autoreleasepool {
                if (files.count >= 200) { [issues addObject:@"达到 200 个缓存文件上限"]; return files; }
                NSDictionary *version = wq_file_version(path);
                if (!version) continue;
                UIImage *image = CCDecode(wq_read(path, 0, &error));
                NSString *mode = [name.lowercaseString containsString:@"dark"] ? @"深色" : [name.lowercaseString containsString:@"light"] ? @"浅色" : @"未知";
                [files addObject:@{@"path":path, @"name":name, @"mode":mode, @"bytes":@(st.st_size),
                    @"width":@(image.CGImage ? CGImageGetWidth(image.CGImage) : 0),
                    @"height":@(image.CGImage ? CGImageGetHeight(image.CGImage) : 0), @"version":version}];
                if (!image) [issues addObject:[NSString stringWithFormat:@"无法解码 %@，已禁止替换", name]];
                }
            }
        }
        }
    }
    if (queue.count || count > 20000) [issues addObject:@"达到 20000 个目录项上限，扫描不完整"];
    return files;
}

@implementation CCEngine
+ (NSString *)appGroup { CCSetup(); return wq_app_group() ?: @""; }
+ (NSString *)logs { return wq_log_text(); }
+ (void)cancelScan {
    @synchronized (CCEngine.class) { [CCScan cancel]; }
    wq_full_scan_stop();
}
+ (NSDictionary *)discover:(BOOL)allowFullScan {
    CCSetup();
    WQScanCancellation *scan = WQScanCancellation.new;
    @synchronized (CCEngine.class) { CCScan = scan; }
    if (!wq_app_group().length) return CCFail(@"签名未提供 App Group。请用支持 App Group 的签名方式重新安装；通配符证书通常不满足要求。");
    CCAllowFullScan = allowFullScan;
    @synchronized (CCRoots) { [CCRoots removeAllObjects]; }
    NSString *remembered = [NSUserDefaults.standardUserDefaults stringForKey:@"CCContainer"];
    if (remembered.length) CCRegisterRoot(remembered);
    if (!CCRoots.count) {
        wq_display_names_reset_miss();
        NSArray *paths = wq_ls_container_paths(nil);
        for (NSString *path in paths) {
            if ([wq_bundle_id_for_container(path) isEqualToString:CCIdentifier]) CCRegisterRoot(path);
        }
        if (!CCRoots.count) {
            NSArray *containers = wq_enumerate(CCParent, 0, scan, nil);
            wq_load_display_names();
            for (NSString *path in containers) {
                if (scan.isCancelled || CCRegisterRoot(path)) break;
            }
        }
    }
    CCAllowFullScan = NO;
    if (scan.isCancelled) return CCFail(@"已停止查找，可随时重试。");
    if (!CCRoots.count) return CCFail(allowFullScan ? @"未能确认 CarPlayWallpaper 容器。请导出日志；可能是签名、访问被拒绝或系统结构变化。" : @"快速定位未找到容器。首次使用可尝试完整扫描，可能需要数分钟。");
    NSString *root = CCRoots.anyObject;
    [NSUserDefaults.standardUserDefaults setObject:root forKey:@"CCContainer"];
    NSMutableArray *issues = NSMutableArray.new;
    NSArray *files = CCWalk(root, issues, scan);
    if (scan.isCancelled) return CCFail(@"已停止查找，可随时重试。");
    return @{@"ok":@YES, @"root":root, @"files":files, @"issues":issues,
        @"message": files.count ? @"已找到壁纸缓存；请选择单个目标进行替换。" : @"容器已找到，但没有可识别的 CPBitmap。请先在车机切换内置壁纸后重试；也可能是格式变化。"};
}
+ (UIImage *)preview:(NSString *)path {
    if (!CCAllowed(path)) return nil;
    return CCDecode(wq_read(path, 0, NULL));
}
+ (NSDictionary *)encode:(UIImage *)image to:(NSString *)path {
    if (!image.CGImage || image.size.width < 1 || image.size.height < 1) return CCFail(@"图片无效");
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (![path.stringByStandardizingPath hasPrefix:[documents stringByAppendingString:@"/"]]) return CCFail(@"导出路径必须在本应用内");
    SEL selector = NSSelectorFromString(@"writeToCPBitmapFile:flags:");
    if (![image respondsToSelector:selector]) return CCFail(@"当前系统不提供 CPBitmap 编码接口");
    BOOL ok = ((BOOL(*)(id, SEL, NSString *, int))objc_msgSend)(image, selector, path, 0);
    UIImage *decoded = ok ? CCDecode([NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil]) : nil;
    if (!decoded.CGImage || CGImageGetWidth(decoded.CGImage) != CGImageGetWidth(image.CGImage) || CGImageGetHeight(decoded.CGImage) != CGImageGetHeight(image.CGImage)) {
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return CCFail(@"CPBitmap 回读尺寸校验失败，未写入系统缓存");
    }
    return @{@"ok":@YES, @"path":path};
}
+ (NSDictionary *)apply:(NSDictionary *)target source:(NSString *)source {
    NSString *path = target[@"path"];
    if (![path isKindOfClass:NSString.class] || !CCAllowed(path)) return CCFail(@"目标不属于已确认的 CarPlayWallpaper 缓存，拒绝写入");
    NSDictionary *expected = target[@"version"];
    if (![expected isKindOfClass:NSDictionary.class] || ![expected isEqual:wq_file_version(path)]) return CCFail(@"缓存已发生变化，请重新扫描后再操作");
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (![source.stringByStandardizingPath hasPrefix:[documents stringByAppendingString:@"/"]]) return CCFail(@"源文件不属于本应用");
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:source error:nil];
    if (!attributes || ![attributes.fileType isEqualToString:NSFileTypeRegular] || attributes.fileSize == 0) return CCFail(@"源文件缺失或无效");
    NSData *data = [NSData dataWithContentsOfFile:source options:NSDataReadingMappedIfSafe error:nil];
    UIImage *newImage = CCDecode(data);
    // Intentionally accept different dimensions: write the source bytes as-is.
    if (!newImage.CGImage) return CCFail(@"源 CPBitmap 无法解码，未写入");
    NSString *error = nil;
    if (!wq_write_if_unchanged(path, data, expected, &error)) return CCFail(error);
    return @{@"ok":@YES, @"message":@"已备份并写入，回读校验通过。请重启 iPhone 后连接车机验证；应用无法自动确认车机显示结果。"};
}
+ (NSArray<NSDictionary *> *)backups {
    NSMutableArray *items = NSMutableArray.new;
    NSString *base = wq_backup_root();
    NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtPath:base];
    for (NSString *relative in enumerator) {
        if (![relative.pathExtension.lowercaseString isEqualToString:@"cpbitmap"]) continue;
        NSString *path = [base stringByAppendingPathComponent:relative];
        NSString *original = wq_backup_original_path(path);
        if (!original.length) continue;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (![attributes.fileType isEqualToString:NSFileTypeRegular]) continue;
        [items addObject:@{@"path":path, @"original":original, @"name":original.lastPathComponent,
            @"date":attributes.fileModificationDate ?: NSDate.distantPast, @"bytes":@(attributes.fileSize)}];
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"date"] compare:a[@"date"]]; }];
}
+ (NSDictionary *)restore:(NSString *)backup {
    CCSetup();
    NSString *original = wq_backup_original_path(backup);
    if (!original || !CCAllowed(original)) return CCFail(@"请先扫描并确认原壁纸容器。只允许恢复仍存在的同一目标文件。");
    NSDictionary *expected = wq_file_version(original);
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:backup error:nil];
    if (!expected || ![attributes.fileType isEqualToString:NSFileTypeRegular] || attributes.fileSize == 0) return CCFail(@"目标或备份文件无效");
    NSData *data = [NSData dataWithContentsOfFile:backup options:NSDataReadingMappedIfSafe error:nil];
    if (!CCDecode(data)) return CCFail(@"备份无法解码，拒绝恢复");
    NSString *error = nil;
    if (!wq_write_if_unchanged(original, data, expected, &error)) return CCFail(error);
    return @{@"ok":@YES, @"message":@"恢复完成，当前版本也已备份。请重启 iPhone 后验证车机显示。"};
}
@end
