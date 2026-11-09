
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
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

static NSString *DIMModel = nil;
static NSString *DIMIdentifier = nil;
static NSString *DIMBoardConfig = nil;

static NSString *DIMIOSVersion = nil;
static NSString *DIMBuild = nil;
static NSString *DIMDarwin = nil;
static NSString *DIMKernelVersion = nil;

static BOOL DIMConfigEnabled = NO;
static BOOL DIMIOSEnabled = NO;
static BOOL DIMInitialized = NO;

static NSString * const DIMDomain = @"com.dim.manager";
static NSString * const DIMProfileKey = @"ActiveProfile";

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


// ------------------------------------------------------------
// PROFILE READING
// ------------------------------------------------------------

static NSString *DIMStringValue(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;

    NSString *string = (NSString *)value;

    if (string.length == 0) return nil;

    return string;
}

static NSDictionary *DIMReadActiveProfile(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)DIMDomain);

    CFPropertyListRef stored =
        CFPreferencesCopyAppValue(
            (__bridge CFStringRef)DIMProfileKey,
            (__bridge CFStringRef)DIMDomain
        );

    NSDictionary *profile = nil;

    if (stored) {
        id object = CFBridgingRelease(stored);

        if ([object isKindOfClass:[NSDictionary class]]) {
            profile = object;
        }
    }

    if (!profile) {
        NSUserDefaults *defaults =
            [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];

        [defaults synchronize];

        id object = [defaults objectForKey:DIMProfileKey];

        if ([object isKindOfClass:[NSDictionary class]]) {
            profile = object;
        }
    }

    return profile;
}

static void DIMLoadProfile(void) {
    NSDictionary *profile = DIMReadActiveProfile();

    if (![profile isKindOfClass:[NSDictionary class]]) return;

    BOOL configApplied = [profile[@"config_applied"] boolValue];
    BOOL iosApplied = [profile[@"ios_applied"] boolValue];

    if (configApplied) {
        NSString *model = DIMStringValue(profile[@"name"]);
        NSString *identifier = DIMStringValue(profile[@"identifier"]);
        NSString *board = DIMStringValue(profile[@"boardconfig"]);

        if (model && identifier && board) {
            DIMModel = [model copy];
            DIMIdentifier = [identifier copy];
            DIMBoardConfig = [board copy];

            DIMConfigEnabled = YES;
        }
    }

    if (iosApplied) {
        NSString *version = DIMStringValue(profile[@"version"]);
        NSString *build = DIMStringValue(profile[@"build"]);
        NSString *darwin = DIMStringValue(profile[@"darwin"]);

        if (version && build && darwin) {
            DIMIOSVersion = [version copy];
            DIMBuild = [build copy];
            DIMDarwin = [darwin copy];

            DIMIOSEnabled = YES;
        }
    }
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
    if (!DIMIOSEnabled || !DIMDarwin.length) return;

    struct utsname info;
    memset(&info, 0, sizeof(info));

    if (uname(&info) != 0) return;

    NSString *original =
        [NSString stringWithUTF8String:info.version];

    NSString *release =
        [NSString stringWithUTF8String:info.release];

    if (!original.length) return;

    if (release.length) {
        DIMKernelVersion =
            [original stringByReplacingOccurrencesOfString:release
                                                 withString:DIMDarwin];
    } else {
        DIMKernelVersion = original;
    }
}


// ------------------------------------------------------------
// SYSCTLBYNAME
// ------------------------------------------------------------

static const char *DIMReplacementForName(const char *name) {
    if (!name) return NULL;

    if (DIMConfigEnabled) {
        if (strcmp(name, "hw.machine") == 0)
            return DIMIdentifier.UTF8String;

        if (strcmp(name, "hw.model") == 0)
            return DIMBoardConfig.UTF8String;
    }

    if (DIMIOSEnabled) {
        if (strcmp(name, "kern.osrelease") == 0)
            return DIMDarwin.UTF8String;

        if (strcmp(name, "kern.osversion") == 0)
            return DIMBuild.UTF8String;

        if (strcmp(name, "kern.version") == 0)
            return DIMKernelVersion.UTF8String;
    }

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

    if (replacement)
        return DIMWriteString(replacement, oldp, oldlenp);

    return DIMOriginalSysctlByName
        ? DIMOriginalSysctlByName(name, oldp, oldlenp, newp, newlen)
        : -1;
}


// ------------------------------------------------------------
// SYSCTL MIB
// ------------------------------------------------------------

static const char *DIMReplacementForMIB(int *name, u_int length) {
    if (!name || length != 2) return NULL;

    if (DIMConfigEnabled && name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE)
            return DIMIdentifier.UTF8String;

        if (name[1] == HW_MODEL)
            return DIMBoardConfig.UTF8String;
    }

    if (DIMIOSEnabled && name[0] == CTL_KERN) {
        if (name[1] == KERN_OSRELEASE)
            return DIMDarwin.UTF8String;

        if (name[1] == KERN_OSVERSION)
            return DIMBuild.UTF8String;

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

    if (replacement)
        return DIMWriteString(replacement, oldp, oldlenp);

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

    if (result != 0 || !info)
        return result;

    if (DIMConfigEnabled) {
        strlcpy(
            info->machine,
            DIMIdentifier.UTF8String,
            sizeof(info->machine)
        );
    }

    if (DIMIOSEnabled) {
        strlcpy(
            info->release,
            DIMDarwin.UTF8String,
            sizeof(info->release)
        );

        if (DIMKernelVersion.length) {
            strlcpy(
                info->version,
                DIMKernelVersion.UTF8String,
                sizeof(info->version)
            );
        }
    }

    return 0;
}


// ------------------------------------------------------------
// UIDevice
// ------------------------------------------------------------

static NSString *DIMDeviceModel(id self, SEL selector) {
    return DIMModel;
}

static NSString *DIMDeviceLocalizedModel(id self, SEL selector) {
    return DIMModel;
}

static NSString *DIMDeviceSystemVersion(id self, SEL selector) {
    return DIMIOSVersion;
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

    if (DIMConfigEnabled) {
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
    }

    if (DIMIOSEnabled) {
        DIMReplaceInstanceMethod(
            cls,
            @selector(systemVersion),
            (IMP)DIMDeviceSystemVersion
        );
    }
}


// ------------------------------------------------------------
// INSTALL HOOKS
// ------------------------------------------------------------

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
}


// ------------------------------------------------------------
// INITIALIZATION
// ------------------------------------------------------------

__attribute__((constructor))
static void DIMInitialize(void) {
    @autoreleasepool {
        NSString *bundleID =
            [[NSBundle mainBundle] bundleIdentifier];

        if (![bundleID isEqualToString:@"ph.telegra.Telegraph"])
            return;

        DIMLoadProfile();

        if (!DIMConfigEnabled && !DIMIOSEnabled)
            return;

        DIMInstallHooks();
    }
}
