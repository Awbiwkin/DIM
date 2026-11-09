
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
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
// DIM PREFERENCES
// ------------------------------------------------------------

static NSString * const DIMDomain = @"com.dim.manager";
static NSString * const DIMProfileKey = @"ActiveProfile";

static NSString *DIMModel = nil;
static NSString *DIMIdentifier = nil;
static NSString *DIMBoard = nil;
static NSString *DIMIOS = nil;
static NSString *DIMBuild = nil;
static NSString *DIMDarwin = nil;
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
// READ PREFERENCES
// ------------------------------------------------------------

static id DIMReadPreference(NSString *key) {
    CFPreferencesAppSynchronize(
        (__bridge CFStringRef)DIMDomain
    );

    CFTypeRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFStringRef)DIMDomain
    );

    if (value) {
        return CFBridgingRelease(value);
    }

    NSUserDefaults *prefs =
        [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];

    return [prefs objectForKey:key];
}

// ------------------------------------------------------------
// LOAD ACTIVE PROFILE
// ------------------------------------------------------------

static BOOL DIMLoadProfile(void) {
    id rawProfile = DIMReadPreference(DIMProfileKey);

    if (![rawProfile isKindOfClass:NSDictionary.class])
        return NO;

    NSDictionary *profile = (NSDictionary *)rawProfile;

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
        ![darwin isKindOfClass:NSString.class])
        return NO;

    if (![model length] ||
        ![identifier length] ||
        ![board length] ||
        ![ios length] ||
        ![build length] ||
        ![darwin length])
        return NO;

    DIMModel = [model copy];
    DIMIdentifier = [identifier copy];
    DIMBoard = [board copy];
    DIMIOS = [ios copy];
    DIMBuild = [build copy];
    DIMDarwin = [darwin copy];

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

    // Оригинальный uname вызывается до установки хуков.
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
                                                 withString:DIMDarwin];
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
        return DIMIdentifier.UTF8String;

    if (strcmp(name, "hw.model") == 0)
        return DIMBoard.UTF8String;

    if (strcmp(name, "kern.osrelease") == 0)
        return DIMDarwin.UTF8String;

    if (strcmp(name, "kern.osversion") == 0)
        return DIMBuild.UTF8String;

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
            return DIMIdentifier.UTF8String;

        if (name[1] == HW_MODEL)
            return DIMBoard.UTF8String;
    }

    if (name[0] == CTL_KERN) {
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

    strlcpy(info->machine, DIMIdentifier.UTF8String,
            sizeof(info->machine));

    strlcpy(info->release, DIMDarwin.UTF8String,
            sizeof(info->release));

    if (DIMKernelVersion.length) {
        strlcpy(info->version, DIMKernelVersion.UTF8String,
                sizeof(info->version));
    }

    return 0;
}

// ------------------------------------------------------------
// UIDEVICE
// ------------------------------------------------------------

static NSString *DIMDeviceModel(id self, SEL selector) {
    return DIMModel;
}

static NSString *DIMDeviceLocalizedModel(id self, SEL selector) {
    return DIMModel;
}

static NSString *DIMDeviceSystemVersion(id self, SEL selector) {
    return DIMIOS;
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
        cls, @selector(model), (IMP)DIMDeviceModel
    );

    DIMReplaceInstanceMethod(
        cls, @selector(localizedModel),
        (IMP)DIMDeviceLocalizedModel
    );

    DIMReplaceInstanceMethod(
        cls, @selector(systemVersion),
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

    // Тот же порядок, что и в рабочей статической версии.
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
