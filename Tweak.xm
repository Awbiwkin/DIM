
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <errno.h>
#import <string.h>

#ifndef KERN_OSVERSION
#define KERN_OSVERSION 65
#endif

static NSString * const DIMDomain = @"com.dim.manager";
static NSString * const DIMTargetBundleID = @"ph.telegra.Telegraph";

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

static NSString *DIMDeviceProduct = nil;
static NSString *DIMDeviceIdentifier = nil;
static NSString *DIMDeviceBoard = nil;
static NSString *DIMSystemVersion = nil;
static NSString *DIMBuildVersion = nil;
static NSString *DIMDarwinVersion = nil;
static NSString *DIMKernelVersion = nil;

static BOOL DIMInitialized = NO;

// ============================================================
// PREFERENCES
// ============================================================

static id DIMCopyPreference(NSString *key) {
    if (!key) return nil;

    CFPropertyListRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFStringRef)DIMDomain
    );

    return value ? CFBridgingRelease(value) : nil;
}

static NSString *DIMStringPreference(NSString *key) {
    id value = DIMCopyPreference(key);

    if ([value isKindOfClass:[NSString class]])
        return value;

    if ([value respondsToSelector:@selector(stringValue)])
        return [value stringValue];

    return nil;
}

// ============================================================
// CATALOG LOOKUP
// ============================================================

static NSDictionary *DIMFindCatalogDevice(NSString *identifier) {
    if (!identifier.length) return nil;

    id catalog = DIMCopyPreference(@"DIMCatalogDevices");

    if (![catalog isKindOfClass:[NSArray class]])
        return nil;

    for (id item in (NSArray *)catalog) {
        if (![item isKindOfClass:[NSDictionary class]])
            continue;

        NSString *itemIdentifier = item[@"identifier"];

        if ([itemIdentifier isKindOfClass:[NSString class]] &&
            [itemIdentifier isEqualToString:identifier]) {
            return item;
        }
    }

    return nil;
}

// ============================================================
// IOS TO DARWIN VERSION
// ============================================================

static NSString *DIMDarwinForIOS(NSString *version) {
    if (!version.length) return nil;

    NSInteger major = [[[version componentsSeparatedByString:@"."]
        firstObject] integerValue];

    switch (major) {
        case 18: return @"24.0.0";
        case 17: return @"23.0.0";
        case 16: return @"22.0.0";
        case 15: return @"21.0.0";
        case 14: return @"20.0.0";
        case 13: return @"19.0.0";
        case 12: return @"18.0.0";
        case 11: return @"17.0.0";
        case 10: return @"16.0.0";
        case 9:  return @"15.0.0";
        case 8:  return @"14.0.0";
        default: return nil;
    }
}

// ============================================================
// LOAD SELECTED PROFILE
// ============================================================

static BOOL DIMLoadSelectedProfile(void) {
    CFPreferencesAppSynchronize(
        (__bridge CFStringRef)DIMDomain
    );

    NSString *identifier =
        DIMStringPreference(@"SelectedModel");

    NSString *version =
        DIMStringPreference(@"SelectedVersion");

    NSString *build =
        DIMStringPreference(@"SelectedBuild");

    if (!identifier.length) {
        NSLog(@"[DIM] No SelectedModel configured");
        return NO;
    }

    NSDictionary *device =
        DIMFindCatalogDevice(identifier);

    if (!device) {
        NSLog(@"[DIM] Device %@ not found in DIMCatalogDevices",
              identifier);
        return NO;
    }

    NSString *name = device[@"name"];
    NSString *board = device[@"boardconfig"];

    if (![name isKindOfClass:[NSString class]] ||
        !name.length) {
        name = identifier;
    }

    if (![board isKindOfClass:[NSString class]])
        board = @"";

    DIMDeviceIdentifier = [identifier copy];
    DIMDeviceProduct = [name copy];
    DIMDeviceBoard = [board copy];

    DIMSystemVersion = [version copy];
    DIMBuildVersion = [build copy];

    DIMDarwinVersion = DIMDarwinForIOS(version);

    NSLog(@"[DIM] Selected device: %@ (%@)",
          DIMDeviceProduct, DIMDeviceIdentifier);

    NSLog(@"[DIM] Selected firmware: %@ (%@)",
          DIMSystemVersion, DIMBuildVersion);

    if (!DIMDarwinVersion.length) {
        NSLog(@"[DIM] Darwin mapping unavailable for %@",
              version);
    }

    return YES;
}

// ============================================================
// ORIGINAL KERNEL INFORMATION
// ============================================================

static void DIMPrepareKernelVersion(void) {
    struct utsname info;
    memset(&info, 0, sizeof(info));

    if (uname(&info) != 0)
        return;

    NSString *original =
        [NSString stringWithUTF8String:info.version];

    NSString *release =
        [NSString stringWithUTF8String:info.release];

    if (!original.length)
        return;

    if (release.length && DIMDarwinVersion.length) {
        DIMKernelVersion =
            [original stringByReplacingOccurrencesOfString:release
                                                 withString:DIMDarwinVersion];
    } else {
        DIMKernelVersion = original;
    }
}

// ============================================================
// SYSCTL STRING OUTPUT
// ============================================================

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

// ============================================================
// SYSCTLBYNAME
// ============================================================

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
            ? DIMOriginalSysctlByName(
                name, oldp, oldlenp, newp, newlen
              )
            : -1;
    }

    const char *replacement =
        DIMReplacementForName(name);

    if (replacement && replacement[0])
        return DIMWriteString(replacement, oldp, oldlenp);

    return DIMOriginalSysctlByName
        ? DIMOriginalSysctlByName(
            name, oldp, oldlenp, newp, newlen
          )
        : -1;
}

// ============================================================
// SYSCTL MIB
// ============================================================

static const char *DIMReplacementForMIB(
    int *name,
    u_int length
) {
    if (!name || length != 2)
        return NULL;

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
            ? DIMOriginalSysctl(
                name, namelen, oldp, oldlenp, newp, newlen
              )
            : -1;
    }

    const char *replacement =
        DIMReplacementForMIB(name, namelen);

    if (replacement && replacement[0])
        return DIMWriteString(replacement, oldp, oldlenp);

    return DIMOriginalSysctl
        ? DIMOriginalSysctl(
            name, namelen, oldp, oldlenp, newp, newlen
          )
        : -1;
}

// ============================================================
// UNAME
// ============================================================

static int DIMHookUname(struct utsname *info) {
    if (!DIMOriginalUname) {
        errno = ENOSYS;
        return -1;
    }

    int result = DIMOriginalUname(info);

    if (result != 0 || !info)
        return result;

    if (DIMDeviceIdentifier.length) {
        strlcpy(
            info->machine,
            DIMDeviceIdentifier.UTF8String,
            sizeof(info->machine)
        );
    }

    if (DIMDarwinVersion.length) {
        strlcpy(
            info->release,
            DIMDarwinVersion.UTF8String,
            sizeof(info->release)
        );
    }

    if (DIMKernelVersion.length) {
        strlcpy(
            info->version,
            DIMKernelVersion.UTF8String,
            sizeof(info->version)
        );
    }

    return result;
}

// ============================================================
// UIDevice
// ============================================================

static NSString *DIMDeviceModel(id self, SEL selector) {
    return DIMDeviceProduct ?: @"";
}

static NSString *DIMDeviceLocalizedModel(id self, SEL selector) {
    return DIMDeviceProduct ?: @"";
}

static NSString *DIMDeviceSystemVersion(id self, SEL selector) {
    return DIMSystemVersion ?: @"";
}

static void DIMReplaceInstanceMethod(
    Class cls,
    SEL selector,
    IMP replacement
) {
    if (!cls || !selector || !replacement)
        return;

    auto method = class_getInstanceMethod(cls, selector);

    if (!method)
        return;

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

// ============================================================
// INSTALL HOOKS
// ============================================================

static void DIMInstallHooks(void) {
    if (DIMInitialized)
        return;

    DIMInitialized = YES;

    DIMPrepareKernelVersion();

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

    DIMInstallUIDeviceHooks();

    NSLog(@"[DIM] Runtime hooks installed");
}

// ============================================================
// INITIALIZATION
// ============================================================

__attribute__((constructor))
static void DIMInitialize(void) {
    @autoreleasepool {
        NSString *bundleID =
            [[NSBundle mainBundle] bundleIdentifier];

        if (![bundleID isEqualToString:DIMTargetBundleID])
            return;

        if (!DIMLoadSelectedProfile()) {
            NSLog(@"[DIM] Profile loading failed");
            return;
        }

        DIMInstallHooks();
    }
}
