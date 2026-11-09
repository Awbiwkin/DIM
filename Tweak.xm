
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
#define DIM_PROFILE_KEY @"ActiveProfile"
#define DIM_TELEGRAM_BUNDLE @"ph.telegra.Telegraph"

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

static IMP DIMOriginalDeviceModel = NULL;
static IMP DIMOriginalLocalizedModel = NULL;
static IMP DIMOriginalSystemVersion = NULL;

static NSString *DIM_PROFILE_MODEL = nil;
static NSString *DIM_PROFILE_ID = nil;
static NSString *DIM_PROFILE_BOARD = nil;
static NSString *DIM_PROFILE_IOS = nil;
static NSString *DIM_PROFILE_BUILD = nil;
static NSString *DIM_PROFILE_DARWIN = nil;

static NSString *DIMKernelVersion = nil;

static BOOL DIMInitialized = NO;
static BOOL DIMProfileLoaded = NO;
static BOOL DIMLoadingProfile = NO;

// ------------------------------------------------------------
// PROFILE READER
// ------------------------------------------------------------

static NSDictionary *DIMReadProfile(void) {
    // First: direct preference plist
    NSString *path =
        @"/var/mobile/Library/Preferences/com.dim.manager.plist";

    NSDictionary *file =
        [NSDictionary dictionaryWithContentsOfFile:path];

    if ([file isKindOfClass:NSDictionary.class]) {
        id profile = file[DIM_PROFILE_KEY];

        if ([profile isKindOfClass:NSDictionary.class])
            return profile;
    }

    // Second: CFPreferences
    CFPreferencesAppSynchronize(
        (__bridge CFStringRef)DIM_DOMAIN
    );

    CFTypeRef value = CFPreferencesCopyAppValue(
        CFSTR("ActiveProfile"),
        CFSTR("com.dim.manager")
    );

    if (value) {
        id profile = CFBridgingRelease(value);

        if ([profile isKindOfClass:NSDictionary.class])
            return profile;
    }

    // Third: NSUserDefaults suite
    NSUserDefaults *defaults =
        [[NSUserDefaults alloc] initWithSuiteName:DIM_DOMAIN];

    id profile = [defaults objectForKey:DIM_PROFILE_KEY];

    if ([profile isKindOfClass:NSDictionary.class])
        return profile;

    return nil;
}

static BOOL DIMStringIsValid(id value) {
    return [value isKindOfClass:NSString.class] &&
           [(NSString *)value length] > 0;
}

// ------------------------------------------------------------
// KERNEL VERSION
// ------------------------------------------------------------

static void DIMPrepareKernelVersion(void) {
    struct utsname info;
    memset(&info, 0, sizeof(info));

    int result = -1;

    if (DIMOriginalUname)
        result = DIMOriginalUname(&info);
    else
        result = uname(&info);

    if (result != 0)
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
// LOAD / REFRESH PROFILE
// ------------------------------------------------------------

static BOOL DIMEnsureProfileLoaded(void) {
    if (DIMLoadingProfile)
        return DIMProfileLoaded;

    @synchronized([NSBundle class]) {
        if (DIMLoadingProfile)
            return DIMProfileLoaded;

        DIMLoadingProfile = YES;

        NSDictionary *profile = DIMReadProfile();

        if (![profile isKindOfClass:NSDictionary.class]) {
            DIMLoadingProfile = NO;
            return NO;
        }

        id model = profile[@"name"];
        id identifier = profile[@"identifier"];
        id board = profile[@"boardconfig"];
        id ios = profile[@"version"];
        id build = profile[@"build"];
        id darwin = profile[@"darwin"];

        BOOL valid =
            DIMStringIsValid(model) &&
            DIMStringIsValid(identifier) &&
            DIMStringIsValid(board) &&
            DIMStringIsValid(ios) &&
            DIMStringIsValid(build) &&
            DIMStringIsValid(darwin);

        if (!valid) {
            DIMLoadingProfile = NO;
            return NO;
        }

        BOOL changed =
            ![DIM_PROFILE_MODEL isEqualToString:model] ||
            ![DIM_PROFILE_ID isEqualToString:identifier] ||
            ![DIM_PROFILE_BOARD isEqualToString:board] ||
            ![DIM_PROFILE_IOS isEqualToString:ios] ||
            ![DIM_PROFILE_BUILD isEqualToString:build] ||
            ![DIM_PROFILE_DARWIN isEqualToString:darwin];

        DIM_PROFILE_MODEL = [model copy];
        DIM_PROFILE_ID = [identifier copy];
        DIM_PROFILE_BOARD = [board copy];
        DIM_PROFILE_IOS = [ios copy];
        DIM_PROFILE_BUILD = [build copy];
        DIM_PROFILE_DARWIN = [darwin copy];

        DIMProfileLoaded = YES;

        if (changed || !DIMKernelVersion)
            DIMPrepareKernelVersion();

        DIMLoadingProfile = NO;
        return YES;
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

    DIMEnsureProfileLoaded();

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

    DIMEnsureProfileLoaded();

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

    DIMEnsureProfileLoaded();

    if (!DIMProfileLoaded)
        return result;

    strlcpy(info->machine, DIM_PROFILE_ID.UTF8String,
            sizeof(info->machine));

    strlcpy(info->release, DIM_PROFILE_DARWIN.UTF8String,
            sizeof(info->release));

    if (DIMKernelVersion.length) {
        strlcpy(info->version, DIMKernelVersion.UTF8String,
                sizeof(info->version));
    }

    return 0;
}

// ------------------------------------------------------------
// UIDevice
// ------------------------------------------------------------

static NSString *DIMDeviceModel(id self, SEL selector) {
    DIMEnsureProfileLoaded();

    if (DIM_PROFILE_MODEL)
        return DIM_PROFILE_MODEL;

    if (DIMOriginalDeviceModel)
        return ((id (*)(id, SEL))DIMOriginalDeviceModel)(self, selector);

    return nil;
}

static NSString *DIMDeviceLocalizedModel(id self, SEL selector) {
    DIMEnsureProfileLoaded();

    if (DIM_PROFILE_MODEL)
        return DIM_PROFILE_MODEL;

    if (DIMOriginalLocalizedModel)
        return ((id (*)(id, SEL))DIMOriginalLocalizedModel)(self, selector);

    return nil;
}

static NSString *DIMDeviceSystemVersion(id self, SEL selector) {
    DIMEnsureProfileLoaded();

    if (DIM_PROFILE_IOS)
        return DIM_PROFILE_IOS;

    if (DIMOriginalSystemVersion)
        return ((id (*)(id, SEL))DIMOriginalSystemVersion)(self, selector);

    return nil;
}

static void DIMReplaceInstanceMethod(
    Class cls,
    SEL selector,
    IMP replacement,
    IMP *original
) {
    if (!cls || !selector || !replacement)
        return;

    Method method = class_getInstanceMethod(cls, selector);

    if (!method)
        return;

    if (original)
        *original = method_getImplementation(method);

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
        (IMP)DIMDeviceModel,
        &DIMOriginalDeviceModel
    );

    DIMReplaceInstanceMethod(
        cls,
        @selector(localizedModel),
        (IMP)DIMDeviceLocalizedModel,
        &DIMOriginalLocalizedModel
    );

    DIMReplaceInstanceMethod(
        cls,
        @selector(systemVersion),
        (IMP)DIMDeviceSystemVersion,
        &DIMOriginalSystemVersion
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

    DIMInstallUIDeviceHooks();

    // First attempt. If preferences are not ready yet,
    // the hooks remain installed and retry on later calls.
    DIMEnsureProfileLoaded();
}

// ------------------------------------------------------------
// INITIALIZATION
// ------------------------------------------------------------

__attribute__((constructor))
static void DIMInitialize(void) {
    @autoreleasepool {
        NSString *bundleID =
            [[NSBundle mainBundle] bundleIdentifier];

        if (![bundleID isEqualToString:DIM_TELEGRAM_BUNDLE])
            return;

        DIMInstallHooks();
    }
}
