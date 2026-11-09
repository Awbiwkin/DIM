
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

static NSString *DIMProfileModel = nil;
static NSString *DIMProfileID = nil;
static NSString *DIMProfileBoard = nil;
static NSString *DIMProfileIOS = nil;
static NSString *DIMProfileBuild = nil;
static NSString *DIMProfileDarwin = nil;
static NSString *DIMKernelVersion = nil;

static BOOL DIMInitialized = NO;

// ------------------------------------------------------------
// LOAD PROFILE AND CHECK PROCESS
// ------------------------------------------------------------

static BOOL DIMLoadConfiguration(void) {
    NSString *bundleID =
        [[NSBundle mainBundle] bundleIdentifier];

    if (!bundleID.length)
        return NO;

    NSUserDefaults *prefs =
        [[NSUserDefaults alloc] initWithSuiteName:@"com.dim.manager"];

    if (!prefs)
        return NO;

    BOOL globalEnabled =
        [prefs boolForKey:@"GlobalProfileEnabled"];

    BOOL onlyEnabled =
        [prefs boolForKey:@"OnlyInEnabled"];

    BOOL allowed = NO;

    if (globalEnabled) {
        allowed = YES;
    } else if (onlyEnabled) {
        NSArray *selectedApps =
            [prefs arrayForKey:@"SelectedApps"];

        allowed = [selectedApps containsObject:bundleID];
    }

    if (!allowed)
        return NO;

    NSDictionary *profile =
        [prefs dictionaryForKey:@"ActiveProfile"];

    if (![profile isKindOfClass:[NSDictionary class]])
        return NO;

    if (![profile[@"config_applied"] boolValue] ||
        ![profile[@"ios_applied"] boolValue])
        return NO;

    DIMProfileModel =
        [profile[@"name"] isKindOfClass:[NSString class]]
        ? profile[@"name"] : nil;

    DIMProfileID =
        [profile[@"identifier"] isKindOfClass:[NSString class]]
        ? profile[@"identifier"] : nil;

    DIMProfileBoard =
        [profile[@"boardconfig"] isKindOfClass:[NSString class]]
        ? profile[@"boardconfig"] : nil;

    DIMProfileIOS =
        [profile[@"version"] isKindOfClass:[NSString class]]
        ? profile[@"version"] : nil;

    DIMProfileBuild =
        [profile[@"build"] isKindOfClass:[NSString class]]
        ? profile[@"build"] : nil;

    DIMProfileDarwin =
        [profile[@"darwin"] isKindOfClass:[NSString class]]
        ? profile[@"darwin"] : nil;

    if (!DIMProfileModel.length ||
        !DIMProfileID.length ||
        !DIMProfileBoard.length ||
        !DIMProfileIOS.length ||
        !DIMProfileBuild.length ||
        !DIMProfileDarwin.length)
        return NO;

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

    if (uname(&info) != 0)
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
    if (!name)
        return NULL;

    if (strcmp(name, "hw.machine") == 0)
        return DIMProfileID.UTF8String;

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

    const char *replacement =
        DIMReplacementForName(name);

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
            return DIMProfileID.UTF8String;

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
        DIMProfileID.UTF8String,
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
// UIDevice
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
        if (!DIMLoadConfiguration())
            return;

        DIMInstallHooks();
    }
}
