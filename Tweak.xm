
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>

#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <errno.h>
#import <string.h>

static NSString *DIM_PROFILE_MODEL = nil;
static NSString *DIM_PROFILE_ID = nil;
static NSString *DIM_PROFILE_BOARD = nil;
static NSString *DIM_PROFILE_IOS = nil;
static NSString *DIM_PROFILE_BUILD = nil;
static NSString *DIM_PROFILE_DARWIN = nil;

#ifndef KERN_OSVERSION
#define KERN_OSVERSION 65
#endif

typedef int (*DIMSysctlByNameFn)(const char *, void *, size_t *, void *, size_t);
typedef int (*DIMSysctlFn)(int *, u_int, void *, size_t *, void *, size_t);
typedef int (*DIMUnameFn)(struct utsname *);

static DIMSysctlByNameFn DIMOriginalSysctlByName = NULL;
static DIMSysctlFn DIMOriginalSysctl = NULL;
static DIMUnameFn DIMOriginalUname = NULL;

static NSString *DIMKernelVersion = nil;
static BOOL DIMInitialized = NO;


// ------------------------------------------------------------
// LOAD PROFILE DIRECTLY FROM PREFERENCES PLIST
// ------------------------------------------------------------

static BOOL DIMLoadProfile(void) {
    NSString *path =
        @"/var/mobile/Library/Preferences/com.dim.manager.plist";

    NSDictionary *root =
        [NSDictionary dictionaryWithContentsOfFile:path];

    if (![root isKindOfClass:[NSDictionary class]])
        return NO;

    NSDictionary *profile = root[@"ActiveProfile"];

    if (![profile isKindOfClass:[NSDictionary class]])
        return NO;

    if (![profile[@"config_applied"] boolValue])
        return NO;

    if (![profile[@"ios_applied"] boolValue])
        return NO;

    id model = profile[@"name"];
    id identifier = profile[@"identifier"];
    id board = profile[@"boardconfig"];
    id version = profile[@"version"];
    id build = profile[@"build"];
    id darwin = profile[@"darwin"];

    if (![model isKindOfClass:[NSString class]] ||
        ![identifier isKindOfClass:[NSString class]] ||
        ![board isKindOfClass:[NSString class]] ||
        ![version isKindOfClass:[NSString class]] ||
        ![build isKindOfClass:[NSString class]] ||
        ![darwin isKindOfClass:[NSString class]]) {
        return NO;
    }

    if (!model.length || !identifier.length ||
        !board.length || !version.length ||
        !build.length || !darwin.length) {
        return NO;
    }

    DIM_PROFILE_MODEL = [model copy];
    DIM_PROFILE_ID = [identifier copy];
    DIM_PROFILE_BOARD = [board copy];
    DIM_PROFILE_IOS = [version copy];
    DIM_PROFILE_BUILD = [build copy];
    DIM_PROFILE_DARWIN = [darwin copy];

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
                                                 withString:DIM_PROFILE_DARWIN];
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
        return DIM_PROFILE_ID.UTF8String;

    if (strcmp(name, "hw.model") == 0)
        return DIM_PROFILE_BOARD.UTF8String;

    if (strcmp(name, "kern.osrelease") == 0)
        return DIM_PROFILE_DARWIN.UTF8String;

    if (strcmp(name, "kern.osversion") == 0)
        return DIM_PROFILE_BUILD.UTF8String;

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

static const char *DIMReplacementForMIB(int *name, u_int length) {
    if (!name || length != 2)
        return NULL;

    if (name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE)
            return DIM_PROFILE_ID.UTF8String;

        if (name[1] == HW_MODEL)
            return DIM_PROFILE_BOARD.UTF8String;
    }

    if (name[0] == CTL_KERN) {
        if (name[1] == KERN_OSRELEASE)
            return DIM_PROFILE_DARWIN.UTF8String;

        if (name[1] == KERN_OSVERSION)
            return DIM_PROFILE_BUILD.UTF8String;

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

    strlcpy(info->machine, DIM_PROFILE_ID.UTF8String, sizeof(info->machine));
    strlcpy(info->release, DIM_PROFILE_DARWIN.UTF8String, sizeof(info->release));

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
    return DIM_PROFILE_MODEL;
}

static NSString *DIMDeviceLocalizedModel(id self, SEL selector) {
    return DIM_PROFILE_MODEL;
}

static NSString *DIMDeviceSystemVersion(id self, SEL selector) {
    return DIM_PROFILE_IOS;
}

static void DIMReplaceInstanceMethod(
    Class cls,
    SEL selector,
    IMP replacement
) {
    if (!cls || !selector || !replacement)
        return;

    Method method = class_getInstanceMethod(cls, selector);

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
        NSString *bundleID =
            [[NSBundle mainBundle] bundleIdentifier];

        if (![bundleID isEqualToString:@"ph.telegra.Telegraph"])
            return;

        if (!DIMLoadProfile())
            return;

        DIMInstallHooks();
    }
}
