#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import "DIMManager.h"

// Перехват C-функции MobileGestalt
extern CFTypeRef MGCopyAnswer(CFStringRef property);
%hookf(CFTypeRef, MGCopyAnswer, CFStringRef property) {
    if (!property) return %orig(property);
    
    NSString *prop = (__bridge NSString *)property;
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    DIMManager *dim = [DIMManager sharedManager];
    
    if (dim.globalEnabled) {
        if ([prop isEqualToString:@"ProductType"]) {
            return (__bridge_retained CFTypeRef)[dim spoofedProductTypeForBundleID:bundleID];
        }
        if ([prop isEqualToString:@"ProductVersion"]) {
            return (__bridge_retained CFTypeRef)[dim spoofedSystemVersionForBundleID:bundleID];
        }
        if ([prop isEqualToString:@"BuildVersion"]) {
            return (__bridge_retained CFTypeRef)[dim spoofedBuildVersionForBundleID:bundleID];
        }
    }
    return %orig(property);
}

// Hook UIDevice
%hook UIDevice
- (NSString *)model {
    if ([[DIMManager sharedManager] globalEnabled]) {
        return @"iPhone";
    }
    return %orig;
}

- (NSString *)systemVersion {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    DIMManager *dim = [DIMManager sharedManager];
    if (dim.globalEnabled) {
        return [dim spoofedSystemVersionForBundleID:bundleID];
    }
    return %orig;
}
%end

// Hook uname для приложений, проверяющих архитектуру/железо на уровне POSIX
%hookf(int, uname, struct utsname *buf) {
    int ret = %orig(buf);
    if (ret == 0 && [[DIMManager sharedManager] globalEnabled]) {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSString *fakeModel = [[DIMManager sharedManager] spoofedProductTypeForBundleID:bundleID];
        const char *cModel = [fakeModel UTF8String];
        strncpy(buf->machine, cModel, sizeof(buf->machine) - 1);
        buf->machine[sizeof(buf->machine) - 1] = '\0';
    }
    return ret;
}
