
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <substrate.h>
#import <dlfcn.h>
#import <errno.h>
#import <string.h>
#import <stdio.h>

static NSString * const DIMDomain = @"com.dim.manager";

typedef CFPropertyListRef (*DIMMGCopyAnswerFunction)(
    CFStringRef, CFDictionaryRef
);

typedef CFPropertyListRef (*DIMMGCopyMultipleAnswersFunction)(
    CFArrayRef, CFDictionaryRef
);

static DIMMGCopyAnswerFunction DIMOriginalMGCopyAnswer = NULL;
static DIMMGCopyMultipleAnswersFunction DIMOriginalMGCopyMultipleAnswers = NULL;

static int (*DIMOriginalSysctlByName)(
    const char *, void *, size_t *, void *, size_t
) = NULL;

static int (*DIMOriginalSysctl)(
    int *, u_int, void *, size_t *, void *, size_t
) = NULL;

static int (*DIMOriginalUname)(struct utsname *) = NULL;


// MARK: - Configuration

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

    if (!global && !onlyIn) {
        return nil;
    }

    NSString *bundleID =
        NSBundle.mainBundle.bundleIdentifier ?: @"";

    if (onlyIn) {
        NSArray *selectedApps = [prefs arrayForKey:@"SelectedApps"];

        if (![selectedApps isKindOfClass:NSArray.class] ||
            ![selectedApps containsObject:bundleID]) {
            return nil;
        }
    }

    NSString *model =
        [prefs stringForKey:@"SelectedModel"] ?: @"";

    NSString *version =
        [prefs stringForKey:@"SelectedVersion"] ?: @"";

    NSString *build =
        [prefs stringForKey:@"SelectedBuild"] ?: @"";

    NSString *family =
        [prefs stringForKey:@"DeviceFamily"] ?: @"";

    if (!model.length && !version.length && !build.length) {
        return nil;
    }

    return @{
        @"model": model,
        @"version": version,
        @"build": build,
        @"family": family
    };
}

static NSString *DIMValue(NSString *key) {
    NSDictionary *config = DIMActiveConfiguration();

    if (!config) return nil;

    id value = config[key];

    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }

    return [value length] ? value : nil;
}


// MARK: - MobileGestalt keys

static NSString *DIMMGKey(CFStringRef key) {
    if (!key || CFGetTypeID(key) != CFStringGetTypeID()) {
        return nil;
    }

    if (CFStringCompare(key, CFSTR("ProductType"), 0) == kCFCompareEqualTo ||
        CFStringCompare(key, CFSTR("h9jDsbgj7xIVeIQ8S3/X3Q"), 0) == kCFCompareEqualTo) {
        return @"model";
    }

    if (CFStringCompare(key, CFSTR("ProductVersion"), 0) == kCFCompareEqualTo ||
        CFStringCompare(key, CFSTR("qNNddlUK+B/YlooNoymwgA"), 0) == kCFCompareEqualTo) {
        return @"version";
    }

    if (CFStringCompare(key, CFSTR("BuildVersion"), 0) == kCFCompareEqualTo ||
        CFStringCompare(key, CFSTR("mZfUC7qo4pURNhyMHZ62RQ"), 0) == kCFCompareEqualTo) {
        return @"build";
    }

    return nil;
}

static CFStringRef DIMCreateCFString(NSString *value) {
    if (!value.length) return NULL;

    return CFStringCreateWithCString(
        kCFAllocatorDefault,
        value.UTF8String,
        kCFStringEncodingUTF8
    );
}


// MARK: - MGCopyAnswer

static CFPropertyListRef DIMHookMGCopyAnswer(
    CFStringRef key,
    CFDictionaryRef options
) {
    NSString *configKey = DIMMGKey(key);

    if (configKey) {
        NSString *replacement = DIMValue(configKey);

        if (replacement.length) {
            CFStringRef result = DIMCreateCFString(replacement);

            if (result) {
                return result;
            }
        }
    }

    if (DIMOriginalMGCopyAnswer) {
        return DIMOriginalMGCopyAnswer(key, options);
    }

    return NULL;
}


// MARK: - MGCopyMultipleAnswers

static CFPropertyListRef DIMHookMGCopyMultipleAnswers(
    CFArrayRef questions,
    CFDictionaryRef options
) {
    if (!DIMOriginalMGCopyMultipleAnswers) {
        return NULL;
    }

    CFPropertyListRef original =
        DIMOriginalMGCopyMultipleAnswers(questions, options);

    if (!original ||
        CFGetTypeID(original) != CFDictionaryGetTypeID()) {
        return original;
    }

    if (!questions ||
        CFGetTypeID(questions) != CFArrayGetTypeID()) {
        return original;
    }

    CFMutableDictionaryRef result =
        CFDictionaryCreateMutableCopy(
            kCFAllocatorDefault,
            0,
            (CFDictionaryRef)original
        );

    if (!result) {
        return original;
    }

    CFIndex count = CFArrayGetCount(questions);
    BOOL changed = NO;

    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef question = CFArrayGetValueAtIndex(questions, i);

        if (!question ||
            CFGetTypeID(question) != CFStringGetTypeID()) {
            continue;
        }

        NSString *configKey = DIMMGKey((CFStringRef)question);

        if (!configKey) continue;

        NSString *replacement = DIMValue(configKey);

        if (!replacement.length) continue;

        CFStringRef replacementValue = DIMCreateCFString(replacement);

        if (!replacementValue) continue;

        CFDictionarySetValue(
            result,
            question,
            replacementValue
        );

        CFRelease(replacementValue);
        changed = YES;
    }

    if (!changed) {
        CFRelease(result);
        return original;
    }

    CFRelease(original);
    return result;
}


// MARK: - sysctl

static int DIMCopyStringToBuffer(
    NSString *replacement,
    void *oldp,
    size_t *oldlenp
) {
    if (!replacement.length) return -1;

    const char *string = replacement.UTF8String;
    size_t required = strlen(string) + 1;

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

    memcpy(oldp, string, required);
    *oldlenp = required;

    return 0;
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

        NSString *replacement = key ? DIMValue(key) : nil;

        if (replacement.length) {
            return DIMCopyStringToBuffer(
                replacement,
                oldp,
                oldlenp
            );
        }
    }

    if (DIMOriginalSysctlByName) {
        return DIMOriginalSysctlByName(
            name, oldp, oldlenp, newp, newlen
        );
    }

    errno = ENOSYS;
    return -1;
}

static int DIMHookSysctl(
    int *name,
    u_int namelen,
    void *oldp,
    size_t *oldlenp,
    void *newp,
    size_t newlen
) {
    if (name && namelen >= 2 && !newp) {
        NSString *key = nil;

        if (name[0] == CTL_HW && name[1] == HW_MACHINE) {
            key = @"model";
        } else if (name[0] == CTL_KERN && name[1] == KERN_OSVERSION) {
            key = @"build";
        }

        NSString *replacement = key ? DIMValue(key) : nil;

        if (replacement.length) {
            return DIMCopyStringToBuffer(
                replacement,
                oldp,
                oldlenp
            );
        }
    }

    if (DIMOriginalSysctl) {
        return DIMOriginalSysctl(
            name, namelen, oldp, oldlenp, newp, newlen
        );
    }

    errno = ENOSYS;
    return -1;
}


// MARK: - uname

static int DIMHookUname(struct utsname *info) {
    if (!DIMOriginalUname) {
        errno = ENOSYS;
        return -1;
    }

    int result = DIMOriginalUname(info);

    if (result != 0 || !info) return result;

    NSString *model = DIMValue(@"model");

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


// MARK: - OS version

static NSOperatingSystemVersion DIMVersionFromString(
    NSString *string,
    NSOperatingSystemVersion fallback
) {
    if (!string.length) return fallback;

    NSArray *parts = [string componentsSeparatedByString:@"."];

    NSOperatingSystemVersion result;
    result.majorVersion =
        parts.count > 0 ? [parts[0] integerValue] : 0;

    result.minorVersion =
        parts.count > 1 ? [parts[1] integerValue] : 0;

    result.patchVersion =
        parts.count > 2 ? [parts[2] integerValue] : 0;

    if (result.majorVersion <= 0) {
        return fallback;
    }

    return result;
}


// MARK: - UIKit

%hook UIDevice

- (NSString *)systemVersion {
    NSString *value = DIMValue(@"version");
    return value.length ? value : %orig;
}

- (NSString *)model {
    NSDictionary *config = DIMActiveConfiguration();

    if (config) {
        NSString *family = config[@"family"];

        if ([family isEqualToString:@"iPad"]) return @"iPad";
        if ([family isEqualToString:@"iPhone"]) return @"iPhone";
    }

    return %orig;
}

- (NSString *)localizedModel {
    NSDictionary *config = DIMActiveConfiguration();

    if (config) {
        NSString *family = config[@"family"];

        if ([family isEqualToString:@"iPad"]) return @"iPad";
        if ([family isEqualToString:@"iPhone"]) return @"iPhone";
    }

    return %orig;
}

- (NSString *)buildVersion {
    NSString *value = DIMValue(@"build");
    return value.length ? value : %orig;
}

%end


// MARK: - NSProcessInfo

%hook NSProcessInfo

- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion original = %orig;

    return DIMVersionFromString(
        DIMValue(@"version"),
        original
    );
}

- (NSString *)operatingSystemVersionString {
    NSString *version = DIMValue(@"version");

    if (version.length) {
        return [NSString stringWithFormat:@"Version %@", version];
    }

    return %orig;
}

%end


// MARK: - Constructor

%ctor {
    @autoreleasepool {
        void *mgHandle = dlopen(
            "/usr/lib/libMobileGestalt.dylib",
            RTLD_NOW | RTLD_GLOBAL
        );

        if (mgHandle) {
            void *answerSymbol =
                dlsym(mgHandle, "MGCopyAnswer");

            if (answerSymbol) {
                MSHookFunction(
                    answerSymbol,
                    (void *)DIMHookMGCopyAnswer,
                    (void **)&DIMOriginalMGCopyAnswer
                );
            }

            void *multipleSymbol =
                dlsym(mgHandle, "MGCopyMultipleAnswers");

            if (multipleSymbol) {
                MSHookFunction(
                    multipleSymbol,
                    (void *)DIMHookMGCopyMultipleAnswers,
                    (void **)&DIMOriginalMGCopyMultipleAnswers
                );
            }
        }

        MSHookFunction(
            (void *)sysctlbyname,
            (void *)DIMHookSysctlByName,
            (void **)&DIMOriginalSysctlByName
        );

        MSHookFunction(
            (void *)sysctl,
            (void *)DIMHookSysctl,
            (void **)&DIMOriginalSysctl
        );

        MSHookFunction(
            (void *)uname,
            (void *)DIMHookUname,
            (void **)&DIMOriginalUname
        );

        NSString *bundleID =
            NSBundle.mainBundle.bundleIdentifier ?: @"unknown";

        NSDictionary *config = DIMActiveConfiguration();

        NSLog(@"[DIM] Runtime loaded: %@", bundleID);

        NSLog(@"[DIM] MGCopyAnswer: %@",
              DIMOriginalMGCopyAnswer ? @"installed" : @"unavailable");

        NSLog(@"[DIM] MGCopyMultipleAnswers: %@",
              DIMOriginalMGCopyMultipleAnswers ? @"installed" : @"unavailable");

        if (config) {
            NSLog(@"[DIM] Active for %@", bundleID);
            NSLog(@"[DIM] ProductType: %@", config[@"model"]);
            NSLog(@"[DIM] ProductVersion: %@", config[@"version"]);
            NSLog(@"[DIM] BuildVersion: %@", config[@"build"]);
        } else {
            NSLog(@"[DIM] Identity inactive for %@", bundleID);
        }
    }
}
