
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

// ------------------------------------------------------------
// DIM SETTINGS
// ------------------------------------------------------------

static NSString * const DIMDomain = @"com.dim.manager";

static NSString * const DIMActiveProfileKey = @"ActiveProfile";
static NSString * const DIMSelectedAppsKey = @"SelectedApps";

static NSString * const DIMGlobalEnabledKey = @"GlobalProfileEnabled";
static NSString * const DIMOnlyInEnabledKey = @"OnlyInEnabled";

// ------------------------------------------------------------
// ACTIVE PROFILE
// ------------------------------------------------------------

static NSString *DIMProfileModel = nil;
static NSString *DIMProfileIdentifier = nil;
static NSString *DIMProfileBoard = nil;
static NSString *DIMProfileIOS = nil;
static NSString *DIMProfileBuild = nil;
static NSString *DIMProfileDarwin = nil;

static NSString *DIMKernelVersion = nil;

static BOOL DIMInitialized = NO;

// ------------------------------------------------------------
// ORIGINAL FUNCTIONS
// ------------------------------------------------------------

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
// LOAD PROFILE AND APPLICATION SCOPE
// ------------------------------------------------------------

static BOOL DIMLoadConfiguration(void) {
    NSUserDefaults *prefs =
        [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];

    if (!prefs) return NO;

    BOOL globalEnabled =
        [prefs boolForKey:DIMGlobalEnabledKey];

    BOOL onlyInEnabled =
        [prefs boolForKey:DIMOnlyInEnabledKey];

    if (!globalEnabled && !onlyInEnabled)
        return NO;

    if (!globalEnabled) {
        NSString *bundleID =
            [[NSBundle mainBundle] bundleIdentifier];

        if (![bundleID isKindOfClass:NSString.class] ||
            bundleID.length == 0) {
            return NO;
        }

        NSArray *selectedApps =
            [prefs arrayForKey:DIMSelectedAppsKey];

        if (![selectedApps isKindOfClass:NSArray.class] ||
            ![selectedApps containsObject:bundleID]) {
            return NO;
        }
    }

    NSDictionary *profile =
        [prefs dictionaryForKey:DIMActiveProfileKey];

    if (![profile isKindOfClass:NSDictionary.class])
        return NO;

    if (![profile[@"config_applied"] boolValue] ||
        ![profile[@"ios_applied"] boolValue]) {
        return NO;
    }

    id model = profile[@"name"];
    id identifier = profile[@"identifier"];
    id board = profile[@"boardconfig"];
    id ios = profile[@"version"];
    id build = profile[@"build"];
    id darwin = profile[@"darwin"];

    if (![model isKindOfClass:NSString.class] ||
        ![identifier isKindOfClass:NSString.class] ||
        ![board isKindOfClass:NSString.class] ||
        ![ios isKindOfClass:NSString.class] ||
        ![build isKindOfClass:NSString.class] ||
        ![darwin isKindOfClass:NSString.class]) {
        return NO;
    }

    if (![(NSString *)model length] ||
        ![(NSString *)identifier length] ||
        ![(NSString *)board length] ||
        ![(NSString *)ios length] ||
        ![(NSString *)build length] ||
        ![(NSString *)darwin length]) {
        return NO;
    }

    DIMProfileModel = [model copy];
    DIMProfileIdentifier = [identifier copy];
    DIMProfileBoard = [board copy];
    DIMProfileIOS = [ios copy];
    DIMProfileBuild = [build copy];
    DIMProfileDarwin = [darwin copy];

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
    if (!DIMOriginalUname)
        return;

    struct utsname info;
    memset(&info, 0, sizeof(info));

    if (DIMOriginalUname(&info) != 0)
        return;

    NSString *original =
        [NSString stringWithUTF8String:info.version];

    NSString *release =
        [NSString stringWithUTF8String:info.release];

    if (!original.length)
        return;

    if (release.length) {
        DIMKernelVersion =
            [original stringByReplacingOccurrencesOfString:release
                                                 withString:DIMProfileDarwin];
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
        return DIMProfileIdentifier.UTF8String;

    if (strcmp(name, "hw.model") == 0)
        return DIMProfileBoard.UTF8String;

    if (strcmp(name, "kern.osrelease") == 0)
        return DIMProfileDarwin.UTF8String;

    if (strcmp(name, "kern.osversion") == 0)
        return DIMProfileBuild.UTF8String;

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

    if (replacement)
        return DIMWriteString(replacement, oldp, oldlenp);

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
    if (!name || length != 2)
        return NULL;

    if (name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE)
            return DIMProfileIdentifier.UTF8String;

        if (name[1] == HW_MODEL)
            return DIMProfileBoard.UTF8String;
    }

    if (name[0] == CTL_KERN) {
        if (name[1] == KERN_OSRELEASE)
            return DIMProfileDarwin.UTF8String;

        if (name[1] == KERN_OSVERSION)
            return DIMProfileBuild.UTF8String;

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

    strlcpy(
        info->machine,
        DIMProfileIdentifier.UTF8String,
        sizeof(info->machine)
    );

    strlcpy(
        info->release,
        DIMProfileDarwin.UTF8String,
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
// UIDEVICE
// ------------------------------------------------------------

static NSString *DIMDeviceModel(id self, SEL selector) {
    return DIMProfileModel;
}

static NSString *DIMDeviceLocalizedModel(id self, SEL selector) {
    return DIMProfileModel;
}

static NSString *DIMDeviceSystemVersion(id self, SEL selector) {
    return DIMProfileIOS;
}

static void DIMReplaceInstanceMethod(
    Class cls,
    SEL selector,
    IMP replacement
) {
    if (!cls || !selector || !replacement)
        return;

    Method method =
        class_getInstanceMethod(cls, selector);

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

// ------------------------------------------------------------
// INSTALL HOOKS
// ------------------------------------------------------------

static void DIMInstallHooks(void) {
    if (DIMInitialized)
        return;

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
        if (!DIMLoadConfiguration())
            return;

        DIMInstallHooks();
    }
}
