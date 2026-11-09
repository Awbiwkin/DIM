
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <substrate.h>
#import <errno.h>
#import <string.h>
#import <stdio.h>

static NSString * const DIMDomain = @"com.dim.manager";

static int (*DIMOriginalSysctlByName)(
    const char *,
    void *,
    size_t *,
    void *,
    size_t
);

static int (*DIMOriginalUname)(struct utsname *);

static NSDictionary *DIMActiveConfiguration(void) {
    NSUserDefaults *prefs =
        [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];

    if (!prefs ||
        ![prefs boolForKey:@"Enabled"] ||
        ![prefs boolForKey:@"DeviceEnabled"]) {
        return nil;
    }

    BOOL global = [prefs boolForKey:@"GlobalProfileEnabled"];
    BOOL onlyIn = [prefs boolForKey:@"OnlyInEnabled"];

    // Без выбранной области применения ничего не подменяем.
    if (!global && !onlyIn) {
        return nil;
    }

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";

    if (onlyIn) {
        NSArray *selectedApps = [prefs arrayForKey:@"SelectedApps"];

        if (![selectedApps isKindOfClass:NSArray.class] ||
            ![selectedApps containsObject:bundleID]) {
            return nil;
        }
    }

    NSString *model = [prefs stringForKey:@"SelectedModel"] ?: @"";
    NSString *version = [prefs stringForKey:@"SelectedVersion"] ?: @"";
    NSString *build = [prefs stringForKey:@"SelectedBuild"] ?: @"";

    if (!model.length && !version.length && !build.length) {
        return nil;
    }

    return @{
        @"model": model,
        @"version": version,
        @"build": build
    };
}

static NSString *DIMConfigurationValue(NSString *key) {
    NSDictionary *config = DIMActiveConfiguration();

    if (!config) {
        return nil;
    }

    NSString *value = config[key];

    return [value isKindOfClass:NSString.class] && value.length
        ? value
        : nil;
}

static int DIMHookSysctlByName(
    const char *name,
    void *oldp,
    size_t *oldlenp,
    void *newp,
    size_t newlen
) {
    if (name && !newp) {
        NSString *key = nil;

        if (strcmp(name, "hw.machine") == 0) {
            key = @"model";
        } else if (strcmp(name, "kern.osversion") == 0) {
            key = @"build";
        }

        NSString *replacement = key
            ? DIMConfigurationValue(key)
            : nil;

        if (replacement.length) {
            size_t required = replacement.length + 1;

            if (!oldp) {
                if (oldlenp) {
                    *oldlenp = required;
                }
                return 0;
            }

            if (!oldlenp || *oldlenp < required) {
                if (oldlenp) {
                    *oldlenp = required;
                }

                errno = ENOMEM;
                return -1;
            }

            memcpy(oldp, replacement.UTF8String, required);
            *oldlenp = required;

            return 0;
        }
    }

    if (DIMOriginalSysctlByName) {
        return DIMOriginalSysctlByName(
            name,
            oldp,
            oldlenp,
            newp,
            newlen
        );
    }

    errno = ENOSYS;
    return -1;
}

static int DIMHookUname(struct utsname *info) {
    if (!DIMOriginalUname) {
        errno = ENOSYS;
        return -1;
    }

    int result = DIMOriginalUname(info);

    if (result != 0 || !info) {
        return result;
    }

    NSString *model = DIMConfigurationValue(@"model");

    if (model.length) {
        memset(info->machine, 0, sizeof(info->machine));

        snprintf(
            info->machine,
            sizeof(info->machine),
            "%s",
            model.UTF8String
        );
    }

    return result;
}

static NSOperatingSystemVersion DIMVersionFromString(
    NSString *versionString,
    NSOperatingSystemVersion fallback
) {
    if (!versionString.length) {
        return fallback;
    }

    NSArray<NSString *> *parts =
        [versionString componentsSeparatedByString:@"."];

    NSOperatingSystemVersion version;
    version.majorVersion = parts.count > 0 ? parts[0].integerValue : 0;
    version.minorVersion = parts.count > 1 ? parts[1].integerValue : 0;
    version.patchVersion = parts.count > 2 ? parts[2].integerValue : 0;

    if (version.majorVersion <= 0) {
        return fallback;
    }

    return version;
}

%hook UIDevice

- (NSString *)systemVersion {
    NSString *version = DIMConfigurationValue(@"version");

    return version.length ? version : %orig;
}

%end

%hook NSProcessInfo

- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion original = %orig;

    NSString *version = DIMConfigurationValue(@"version");

    return DIMVersionFromString(version, original);
}

- (NSString *)operatingSystemVersionString {
    NSString *version = DIMConfigurationValue(@"version");

    if (version.length) {
        return [NSString stringWithFormat:@"Version %@", version];
    }

    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        MSHookFunction(
            (void *)sysctlbyname,
            (void *)DIMHookSysctlByName,
            (void **)&DIMOriginalSysctlByName
        );

        MSHookFunction(
            (void *)uname,
            (void *)DIMHookUname,
            (void **)&DIMOriginalUname
        );

        NSString *bundleID =
            NSBundle.mainBundle.bundleIdentifier ?: @"unknown";

        NSLog(@"[DIM] Runtime loaded: %@", bundleID);

        NSDictionary *config = DIMActiveConfiguration();

        if (config) {
            NSLog(@"[DIM] Identity active for %@", bundleID);
            NSLog(@"[DIM] Model: %@", config[@"model"]);
            NSLog(@"[DIM] iOS: %@", config[@"version"]);
            NSLog(@"[DIM] Build: %@", config[@"build"]);
        } else {
            NSLog(@"[DIM] Identity inactive for %@", bundleID);
        }
    }
}
