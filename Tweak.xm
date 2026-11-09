#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>

#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <errno.h>
#import <string.h>

#import "DIMRuntime.h"

#ifndef KERN_OSVERSION
#define KERN_OSVERSION 65
#endif

// ------------------------------------------------------------
// ПРОФИЛЬ (читается из runtime plist, который пишет менеджер)
// ------------------------------------------------------------
//
// Тут больше нет захардкоженного iPhone 15 Pro Max. Значения лежат в обычных
// C-буферах, чтобы хуки отдавали стабильные указатели.

static char gMachine[64];        // iPhone16,2
static char gBoard[64];          // D84AP
static char gFamily[16];         // iPhone / iPad
static char gVersion[32];        // 18.0
static char gBuild[32];          // 22A3354
static char gDarwin[32];         // 24.0.0
static char gKernelVersion[512]; // kern.version с подставленным Darwin

static BOOL gHasConfig = NO;     // применена модель (Apply Config)
static BOOL gHasIOS = NO;        // применена версия iOS (Apply iOS)
static BOOL gInstalled = NO;

static int gBeaconTokens[2];
static int gBeaconTokenCount = 0;

typedef int (*DIMSysctlByNameFn)(const char *, void *, size_t *, void *, size_t);
typedef int (*DIMSysctlFn)(int *, u_int, void *, size_t *, void *, size_t);
typedef int (*DIMUnameFn)(struct utsname *);

static DIMSysctlByNameFn DIMOriginalSysctlByName = NULL;
static DIMSysctlFn DIMOriginalSysctl = NULL;
static DIMUnameFn DIMOriginalUname = NULL;

// ------------------------------------------------------------
// ЗАГРУЗКА КОНФИГА
// ------------------------------------------------------------

static NSDictionary *DIMReadRuntime(void) {
    NSDictionary *config =
        [NSDictionary dictionaryWithContentsOfFile:DIM_RUNTIME_PATH];

    if ([config isKindOfClass:[NSDictionary class]]) return config;

    // Запасной путь для rootless-окружений.
    config = [NSDictionary dictionaryWithContentsOfFile:
              @"/var/jb/var/mobile/Library/Preferences/com.dim.manager.runtime.plist"];

    return [config isKindOfClass:[NSDictionary class]] ? config : nil;
}

static NSString *DIMString(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    return ([value isKindOfClass:[NSString class]] && [value length]) ? value : nil;
}

static BOOL DIMInScope(NSDictionary *config, NSString *bundleID) {
    if (!bundleID.length) return NO;

    // Эти процессы никогда не трогаем: иначе сломаем сам менеджер и систему.
    if ([bundleID isEqualToString:@"com.apple.springboard"] ||
        [bundleID isEqualToString:@"com.apple.Preferences"]) {
        return NO;
    }

    if (![config[@"Enabled"] boolValue]) return NO;
    if (![config[@"DeviceEnabled"] boolValue]) return NO;

    // Global — все приложения на UIKit.
    if ([config[@"Global"] boolValue]) return YES;

    // Only in — только выбранные приложения.
    if ([config[@"OnlyIn"] boolValue]) {
        NSArray *apps = config[@"Apps"];

        return [apps isKindOfClass:[NSArray class]] &&
               [apps containsObject:bundleID];
    }

    return NO;
}

static BOOL DIMLoadProfile(NSDictionary *profile) {
    if (![profile isKindOfClass:[NSDictionary class]]) return NO;

    NSString *identifier = DIMString(profile, @"identifier");
    NSString *board = DIMString(profile, @"boardconfig");
    NSString *version = DIMString(profile, @"version");
    NSString *build = DIMString(profile, @"build");
    NSString *darwin = DIMString(profile, @"darwin");

    gHasConfig = [profile[@"config_applied"] boolValue] && identifier && board;
    gHasIOS = [profile[@"ios_applied"] boolValue] && version && build && darwin;

    if (gHasConfig) {
        strlcpy(gMachine, identifier.UTF8String, sizeof(gMachine));
        strlcpy(gBoard, board.UTF8String, sizeof(gBoard));
        strlcpy(gFamily, [identifier hasPrefix:@"iPad"] ? "iPad" : "iPhone",
                sizeof(gFamily));
    }

    if (gHasIOS) {
        strlcpy(gVersion, version.UTF8String, sizeof(gVersion));
        strlcpy(gBuild, build.UTF8String, sizeof(gBuild));
        strlcpy(gDarwin, darwin.UTF8String, sizeof(gDarwin));
    }

    return gHasConfig || gHasIOS;
}

// ------------------------------------------------------------
// SYSCTL OUTPUT
// ------------------------------------------------------------

// Ведёт себя как настоящий sysctl: вызов с oldp == NULL возвращает только размер,
// слишком маленький буфер -> ENOMEM и нужный размер.
static int DIMWriteString(const char *value, void *oldp, size_t *oldlenp) {
    if (!value || !oldlenp) {
        errno = EFAULT;
        return -1;
    }

    size_t required = strlen(value) + 1;

    if (!oldp) {
        *oldlenp = required;
        return 0;
    }

    if (*oldlenp < required) {
        *oldlenp = required;
        errno = ENOMEM;
        return -1;
    }

    memcpy(oldp, value, required);
    *oldlenp = required;

    return 0;
}

// ------------------------------------------------------------
// KERNEL VERSION
// ------------------------------------------------------------

static void DIMPrepareKernelVersion(void) {
    gKernelVersion[0] = '\0';

    if (!gHasIOS) return;

    struct utsname info;
    memset(&info, 0, sizeof(info));

    // Хуки ещё не установлены, uname вернёт настоящие значения.
    if (uname(&info) != 0) return;

    NSString *original = [NSString stringWithUTF8String:info.version];
    NSString *release = [NSString stringWithUTF8String:info.release];

    if (!original.length) return;

    NSString *patched = original;

    if (release.length) {
        patched = [original
            stringByReplacingOccurrencesOfString:release
                                      withString:[NSString stringWithUTF8String:gDarwin]];
    }

    strlcpy(gKernelVersion, patched.UTF8String, sizeof(gKernelVersion));
}

// ------------------------------------------------------------
// SYSCTLBYNAME
// ------------------------------------------------------------

static const char *DIMReplacementForName(const char *name) {
    if (!name) return NULL;

    if (gHasConfig) {
        if (strcmp(name, "hw.machine") == 0) return gMachine;
        if (strcmp(name, "hw.model") == 0) return gBoard;
    }

    if (gHasIOS) {
        if (strcmp(name, "kern.osrelease") == 0) return gDarwin;
        if (strcmp(name, "kern.osversion") == 0) return gBuild;
        if (strcmp(name, "kern.version") == 0 && gKernelVersion[0])
            return gKernelVersion;
    }

    return NULL;
}

static int DIMHookSysctlByName(
    const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen
) {
    if (newp == NULL) {
        const char *replacement = DIMReplacementForName(name);

        if (replacement)
            return DIMWriteString(replacement, oldp, oldlenp);
    }

    return DIMOriginalSysctlByName
        ? DIMOriginalSysctlByName(name, oldp, oldlenp, newp, newlen)
        : -1;
}

// ------------------------------------------------------------
// SYSCTL MIB
// ------------------------------------------------------------

static const char *DIMReplacementForMIB(int *name, u_int length) {
    if (!name || length != 2) return NULL;

    if (gHasConfig && name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE) return gMachine;
        if (name[1] == HW_MODEL) return gBoard;
    }

    if (gHasIOS && name[0] == CTL_KERN) {
        if (name[1] == KERN_OSRELEASE) return gDarwin;
        if (name[1] == KERN_OSVERSION) return gBuild;
        if (name[1] == KERN_VERSION && gKernelVersion[0]) return gKernelVersion;
    }

    return NULL;
}

static int DIMHookSysctl(
    int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen
) {
    if (newp == NULL) {
        const char *replacement = DIMReplacementForMIB(name, namelen);

        if (replacement)
            return DIMWriteString(replacement, oldp, oldlenp);
    }

    return DIMOriginalSysctl
        ? DIMOriginalSysctl(name, namelen, oldp, oldlenp, newp, newlen)
        : -1;
}

// ------------------------------------------------------------
// UNAME
// ------------------------------------------------------------

static int DIMHookUname(struct utsname *info) {
    if (!DIMOriginalUname) {
        errno = ENOSYS;
        return -1;
    }

    int result = DIMOriginalUname(info);

    if (result != 0 || !info) return result;

    if (gHasConfig)
        strlcpy(info->machine, gMachine, sizeof(info->machine));

    if (gHasIOS) {
        strlcpy(info->release, gDarwin, sizeof(info->release));

        if (gKernelVersion[0])
            strlcpy(info->version, gKernelVersion, sizeof(info->version));
    }

    return 0;
}

// ------------------------------------------------------------
// UIDevice
// ------------------------------------------------------------

// UIDevice.model в настоящей системе — это "iPhone" / "iPad", а не маркетинговое
// название. Приложения часто сравнивают именно с этими строками.
static NSString *DIMDeviceModel(id self, SEL selector) {
    return [NSString stringWithUTF8String:gFamily];
}

static NSString *DIMDeviceSystemVersion(id self, SEL selector) {
    return [NSString stringWithUTF8String:gVersion];
}

static void DIMReplaceInstanceMethod(Class cls, SEL selector, IMP replacement) {
    if (!cls || !selector || !replacement) return;

    Method method = class_getInstanceMethod(cls, selector);

    if (!method) return;

    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}

static void DIMInstallUIDeviceHooks(void) {
    Class cls = [UIDevice class];

    if (gHasConfig) {
        DIMReplaceInstanceMethod(cls, @selector(model), (IMP)DIMDeviceModel);
        DIMReplaceInstanceMethod(cls, @selector(localizedModel), (IMP)DIMDeviceModel);
    }

    if (gHasIOS) {
        DIMReplaceInstanceMethod(cls, @selector(systemVersion),
                                 (IMP)DIMDeviceSystemVersion);
    }
}

// ------------------------------------------------------------
// ПРОВЕРКА ИЗ НАСТРОЕК ("Check")
// ------------------------------------------------------------
//
// После установки хуков приложение само читает значения теми же вызовами, которыми
// пользуются обычные приложения, считает хеш и кладёт его в состояние darwin-уведомления.
// Настройки сравнивают этот хеш с ожидаемым. Так Check проверяет то, что реально
// видит приложение, а не просто наличие профиля.
// Формат строки обязан совпадать с checkActiveProfile в DIMDeviceListController.m:
//   hw.machine | kern.osversion | kern.osrelease | uname.machine | systemVersion

static void DIMPublishBeacon(NSString *bundleID) {
    char machine[64] = {0};
    char build[32] = {0};
    char release[32] = {0};

    size_t size = sizeof(machine);
    sysctlbyname("hw.machine", machine, &size, NULL, 0);

    size = sizeof(build);
    sysctlbyname("kern.osversion", build, &size, NULL, 0);

    size = sizeof(release);
    sysctlbyname("kern.osrelease", release, &size, NULL, 0);

    struct utsname info;
    memset(&info, 0, sizeof(info));
    uname(&info);

    NSString *systemVersion = [UIDevice currentDevice].systemVersion ?: @"";

    NSString *signature =
        [NSString stringWithFormat:@"%s|%s|%s|%s|%@",
         machine, build, release, info.machine, systemVersion];

    uint64_t hash = DIMFNV1a(signature.UTF8String);

    NSLog(@"[DIM] active in %@: %@", bundleID, signature);

    NSArray *names = @[
        [@"com.dim.verify." stringByAppendingString:bundleID],
        @"com.dim.verify.last"
    ];

    for (NSString *name in names) {
        int token = 0;

        if (notify_register_check(name.UTF8String, &token) != NOTIFY_STATUS_OK)
            continue;

        notify_set_state(token, hash);
        notify_post(name.UTF8String);

        // Токен держим открытым, пока живёт приложение: иначе notifyd забудет состояние.
        if (gBeaconTokenCount < 2) {
            gBeaconTokens[gBeaconTokenCount++] = token;
        } else {
            notify_cancel(token);
        }
    }
}

// ------------------------------------------------------------
// INSTALL HOOKS
// ------------------------------------------------------------

static void DIMInstallHooks(void) {
    if (gInstalled) return;

    gInstalled = YES;

    DIMPrepareKernelVersion();

    MSHookFunction((void *)&sysctlbyname, (void *)DIMHookSysctlByName,
                   (void **)&DIMOriginalSysctlByName);

    MSHookFunction((void *)&sysctl, (void *)DIMHookSysctl,
                   (void **)&DIMOriginalSysctl);

    MSHookFunction((void *)&uname, (void *)DIMHookUname,
                   (void **)&DIMOriginalUname);

    DIMInstallUIDeviceHooks();
}

// ------------------------------------------------------------
// INITIALIZATION
// ------------------------------------------------------------

__attribute__((constructor))
static void DIMInitialize(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];

        if (!bundleID.length) return;

        if ([bundleID isEqualToString:@"com.apple.springboard"] ||
            [bundleID isEqualToString:@"com.apple.Preferences"]) {
            return;
        }

        NSDictionary *config = DIMReadRuntime();

        if (!config) {
            NSLog(@"[DIM] runtime config not readable (open DIM settings once): %@",
                  bundleID);
            return;
        }

        // Приложение не выбрано / модуль выключен -> ничего не делаем.
        if (!DIMInScope(config, bundleID)) return;

        if (!DIMLoadProfile(config[@"Profile"])) {
            NSLog(@"[DIM] %@: profile is empty or incomplete, press Apply in DIM settings",
                  bundleID);
            return;
        }

        DIMInstallHooks();
        DIMPublishBeacon(bundleID);
    }
}
