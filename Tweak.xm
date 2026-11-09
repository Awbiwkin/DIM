
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <errno.h>
#import <string.h>

#define DIM_DOMAIN @"com.dim.manager"

#ifndef KERN_OSVERSION
#define KERN_OSVERSION 65
#endif

typedef int (*DIMSysctlByNameFn)(
    const char *, void *, size_t *, void *, size_t
);

typedef int (*DIMSysctlFn)(
    int *, u_int, void *, size_t *, void *, size_t
);

typedef int (*DIMUnameFn)(struct utsname *);

static DIMSysctlByNameFn DIMOriginalSysctlByName = NULL;
static DIMSysctlFn DIMOriginalSysctl = NULL;
static DIMUnameFn DIMOriginalUname = NULL;

static NSString *DIMDeviceName = nil;
static NSString *DIMDeviceIdentifier = nil;
static NSString *DIMDeviceBoard = nil;
static NSString *DIMSystemVersion = nil;
static NSString *DIMBuildVersion = nil;
static NSString *DIMDarwinVersion = nil;
static NSString *DIMKernelVersion = nil;

static BOOL DIMInitialized = NO;

// ------------------------------------------------------------
// PREFERENCES
// ------------------------------------------------------------

static NSUserDefaults *DIMPreferences(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:DIM_DOMAIN];
}

static NSString *DIMStringValue(id value) {
    if (!value || value == [NSNull null]) return nil;

    if ([value isKindOfClass:NSString.class]) {
        NSString *string = (NSString *)value;
        return string.length ? string : nil;
    }

    return nil;
}

static BOOL DIMApplicationAllowed(
    NSUserDefaults *prefs,
    NSString *bundleID
) {
    if ([prefs boolForKey:@"GlobalProfileEnabled"]) {
        return YES;
    }

    if (![prefs boolForKey:@"OnlyInEnabled"]) {
        return NO;
    }

    NSArray *apps = [prefs arrayForKey:@"SelectedApps"];

    if (![apps isKindOfClass:NSArray.class]) {
        return NO;
    }

    return [apps containsObject:bundleID];
}

// ------------------------------------------------------------
// DARWIN VERSION
// ------------------------------------------------------------

static NSString *DIMDarwinForIOS(NSString *version) {
    if (!version.length) return nil;

    NSArray *parts = [version componentsSeparatedByString:@"."];

    if (parts.count == 0) return nil;

    NSInteger major = [parts[0] integerValue];
    NSInteger minor = 0;

    if (parts.count > 1) {
        minor = [parts[1] integerValue];
    }

    if (major < 13 || major > 30) return nil;

    NSInteger darwinMajor = major + 6;

    return [NSString stringWithFormat:@"%ld.%ld.0",
            (long)darwinMajor,
            (long)minor];
}

// ------------------------------------------------------------
// PROFILE LOADING
// ------------------------------------------------------------

static BOOL DIMLoadProfile(void) {
    NSUserDefaults *prefs = DIMPreferences();

    [prefs synchronize];

    if (![prefs boolForKey:@"Enabled"]) return NO;
    if (![prefs boolForKey:@"DeviceEnabled"]) return NO;

    NSString *bundleID =
        [[NSBundle mainBundle] bundleIdentifier];

    if (!bundleID.length) return NO;

    if (![bundleID isEqualToString:@"ph.telegra.Telegraph"]) {
        return NO;
    }

    if (!DIMApplicationAllowed(prefs, bundleID)) {
        return NO;
    }

    NSString *identifier =
        DIMStringValue([prefs objectForKey:@"SelectedModel"]);

    NSString *version =
        DIMStringValue([prefs objectForKey:@"SelectedVersion"]);

    NSString *build =
        DIMStringValue([prefs objectForKey:@"SelectedBuild"]);

    if (!identifier.length ||
        !version.length ||
        !build.length) {
        return NO;
    }

    if (![identifier hasPrefix:@"iPhone"] &&
        ![identifier hasPrefix:@"iPad"]) {
        return NO;
    }

    NSArray *devices =
        [prefs arrayForKey:@"DIMCatalogDevices"];

    if (![devices isKindOfClass:NSArray.class]) {
        return NO;
    }

    NSDictionary *selectedDevice = nil;

    for (id item in devices) {
        if (![item isKindOfClass:NSDictionary.class]) continue;

        NSDictionary *device = item;

        NSString *candidate =
            DIMStringValue(device[@"identifier"]);

        if ([candidate isEqualToString:identifier]) {
            selectedDevice = device;
            break;
        }
    }

    if (!selectedDevice) return NO;

    NSString *name =
        DIMStringValue(selectedDevice[@"name"]);

    NSString *board =
        DIMStringValue(selectedDevice[@"boardconfig"]);

    NSString *darwin = DIMDarwinForIOS(version);

    if (!name.length || !darwin.length) {
        return NO;
    }

    DIMDeviceName = [name copy];
    DIMDeviceIdentifier = [identifier copy];
    DIMDeviceBoard = [board copy];
    DIMSystemVersion = [version copy];
    DIMBuildVersion = [build copy];
    DIMDarwinVersion = [darwin copy];

    return YES;
}

// ------------------------------------------------------------
// SYSCTL OUTPUT
// ------------------------------------------------------------

static int DIMWriteString(
    const char *value,
    void *oldp,
    size_t *oldlenp
) {
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
    struct utsname info;
    memset(&info, 0, sizeof(info));

    if (!DIMOriginalUname) return;

    if (DIMOriginalUname(&info) != 0) return;

    NSString *original =
        [NSString stringWithUTF8String:info.version];

    NSString *release =
        [NSString stringWithUTF8String:info.release];

    if (!original.length) return;

    if (release.length) {
        DIMKernelVersion =
            [original stringByReplacingOccurrencesOfString:release
                                                 withString:DIMDarwinVersion];
    } else {
        DIMKernelVersion = original;
    }
}

// ------------------------------------------------------------
// SYSCTLBYNAME
// ------------------------------------------------------------

static const char *DIMReplacementForName(const char *name) {
    if (!name) return NULL;

    if (strcmp(name, "hw.machine") == 0)
        return DIMDeviceIdentifier.UTF8String;

    if (strcmp(name, "hw.model") == 0)
        return DIMDeviceBoard.UTF8String;

    if (strcmp(name, "kern.osrelease") == 0)
        return DIMDarwinVersion.UTF8String;

    if (strcmp(name, "kern.osversion") == 0)
        return DIMBuildVersion.UTF8String;

    if (strcmp(name, "kern.version") == 0)
        return DIMKernelVersion.UTF8String;

    return NULL;
}

static int DIMHookSysctlByName(
    const char *name,
    void *oldp,
    size_t *oldlenp,
    void *newp,
    size_t newlen
) {
    if (newp != NULL) {
        return DIMOriginalSysctlByName
            ? DIMOriginalSysctlByName(name, oldp, oldlenp, newp, newlen)
            : -1;
    }

    const char *replacement = DIMReplacementForName(name);

    if (replacement) {
        return DIMWriteString(replacement, oldp, oldlenp);
    }

    return DIMOriginalSysctlByName
        ? DIMOriginalSysctlByName(name, oldp, oldlenp, newp, newlen)
        : -1;
}

// ------------------------------------------------------------
// SYSCTL MIB
// ------------------------------------------------------------

static const char *DIMReplacementForMIB(
    int *name,
    u_int length
) {
    if (!name || length != 2) return NULL;

    if (name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE)
            return DIMDeviceIdentifier.UTF8String;

        if (name[1] == HW_MODEL)
            return DIMDeviceBoard.UTF8String;
    }

    if (name[0] == CTL_KERN) {
        if (name[1] == KERN_OSRELEASE)
            return DIMDarwinVersion.UTF8String;

        if (name[1] == KERN_OSVERSION)
            return DIMBuildVersion.UTF8String;

        if (name[1] == KERN_VERSION)
            return DIMKernelVersion.UTF8String;
    }

    return NULL;
}

static int DIMHookSysctl(
    int *name,
    u_int namelen,
    void *oldp,
    size_t *oldlenp,
    void *newp,
    size_t newlen
) {
    if (newp != NULL) {
        return DIMOriginalSysctl
            ? DIMOriginalSysctl(name, namelen, oldp, oldlenp, newp, newlen)
            : -1;
    }

    const char *replacement =
        DIMReplacementForMIB(name, namelen);

    if (replacement) {
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

    if (result != 0 || !info) {
        return result;
    }

    strlcpy(
        info->machine,
        DIMDeviceIdentifier.UTF8String,
        sizeof(info->machine)
    );

    strlcpy(
        info->release,
        DIMDarwinVersion.UTF8String,
        sizeof(info->release)
    );

    if (DIMKernelVersion.length) {
        strlcpy(
            info->version,
            DIMKernelVersion.UTF8String,
            sizeof(info->version)
        );
    }

    return 0;
}

// ------------------------------------------------------------
// UIDevice
// ------------------------------------------------------------

static NSString *DIMDeviceModel(id self, SEL selector) {
    return DIMDeviceName;
}

static NSString *DIMDeviceLocalizedModel(id self, SEL selector) {
    return DIMDeviceName;
}

static NSString *DIMDeviceSystemVersion(id self, SEL selector) {
    return DIMSystemVersion;
}

static void DIMReplaceInstanceMethod(
    Class cls,
    SEL selector,
    IMP replacement
) {
    if (!cls || !selector || !replacement) return;

    auto method = class_getInstanceMethod(cls, selector);

    if (!method) return;

    class_replaceMethod(
        cls,
        selector,
        replacement,
        method_getTypeEncoding(method)
    );
}

static void DIMInstallUIDeviceHooks(void) {
    Class cls = [UIDevice class];

    DIMReplaceInstanceMethod(
        cls,
        @selector(model),
        (IMP)DIMDeviceModel
    );

    DIMReplaceInstanceMethod(
        cls,
        @selector(localizedModel),
        (IMP)DIMDeviceLocalizedModel
    );

    DIMReplaceInstanceMethod(
        cls,
        @selector(systemVersion),
        (IMP)DIMDeviceSystemVersion
    );
}

// ------------------------------------------------------------
// INSTALL HOOKS
// ------------------------------------------------------------

static void DIMInstallHooks(void) {
    if (DIMInitialized) return;

    DIMInitialized = YES;

    MSHookFunction(
        (void *)&sysctlbyname,
        (void *)DIMHookSysctlByName,
        (void **)&DIMOriginalSysctlByName
    );

    MSHookFunction(
        (void *)&sysctl,
        (void *)DIMHookSysctl,
        (void **)&DIMOriginalSysctl
    );

    MSHookFunction(
        (void *)&uname,
        (void *)DIMHookUname,
        (void **)&DIMOriginalUname
    );

    DIMPrepareKernelVersion();
    DIMInstallUIDeviceHooks();
}

// ------------------------------------------------------------
// INITIALIZATION
// ------------------------------------------------------------

__attribute__((constructor))
static void DIMInitialize(void) {
    @autoreleasepool {
        if (!DIMLoadProfile()) return;

        DIMInstallHooks();
    }
}
