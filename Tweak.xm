
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString * const DIMDomain = @"com.dim.manager";

static NSDictionary *DIMReadConfiguration(void) {
    NSUserDefaults *prefs =
        [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];

    if (!prefs) {
        return @{};
    }

    return @{
        @"enabled": @([prefs boolForKey:@"Enabled"]),
        @"deviceEnabled": @([prefs boolForKey:@"DeviceEnabled"]),
        @"globalProfile": @([prefs boolForKey:@"GlobalProfileEnabled"]),
        @"perAppProfiles": @([prefs boolForKey:@"PerAppProfilesEnabled"]),
        @"selectedModel": [prefs stringForKey:@"SelectedModel"] ?: @"",
        @"selectedVersion": [prefs stringForKey:@"SelectedVersion"] ?: @"",
        @"selectedBuild": [prefs stringForKey:@"SelectedBuild"] ?: @""
    };
}

%ctor {
    @autoreleasepool {
        NSString *bundleID =
            NSBundle.mainBundle.bundleIdentifier ?: @"unknown";

        NSDictionary *config = DIMReadConfiguration();

        NSLog(@"[DIM] Device Identity Manager loaded");
        NSLog(@"[DIM] Process: %@", bundleID);
        NSLog(@"[DIM] Enabled: %@", config[@"enabled"]);
        NSLog(@"[DIM] Device module: %@", config[@"deviceEnabled"]);
        NSLog(@"[DIM] Global profile: %@", config[@"globalProfile"]);
        NSLog(@"[DIM] Per-app profiles: %@", config[@"perAppProfiles"]);
        NSLog(@"[DIM] Selected model: %@", config[@"selectedModel"]);
        NSLog(@"[DIM] Selected OS: %@ (%@)",
              config[@"selectedVersion"],
              config[@"selectedBuild"]);
    }
}
