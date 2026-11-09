
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/stat.h>

static void DIMCheckValue(NSDictionary *profile, NSString *key) {
    id value = profile[key];

    if (!value) {
        NSLog(@"[DIM-DIAG] %@ = MISSING", key);
        return;
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSLog(@"[DIM-DIAG] %@ = %@", key, value);
        return;
    }

    if ([value respondsToSelector:@selector(stringValue)]) {
        NSLog(@"[DIM-DIAG] %@ = %@", key, [value stringValue]);
        return;
    }

    NSLog(@"[DIM-DIAG] %@ = PRESENT (type: %@)",
          key, NSStringFromClass([value class]));
}

__attribute__((constructor))
static void DIMDiagnosticInitialize(void) {
    @autoreleasepool {
        NSString *bundleID =
            [[NSBundle mainBundle] bundleIdentifier];

        if (![bundleID isEqualToString:@"ph.telegra.Telegraph"])
            return;

        NSString *path =
            @"/var/mobile/Library/Preferences/com.dim.manager.plist";

        NSLog(@"[DIM-DIAG] ===== START =====");
        NSLog(@"[DIM-DIAG] Bundle: %@", bundleID);
        NSLog(@"[DIM-DIAG] Path: %@", path);

        struct stat st;
        if (stat(path.fileSystemRepresentation, &st) == 0) {
            NSLog(@"[DIM-DIAG] FILE = FOUND, size = %lld",
                  (long long)st.st_size);
        } else {
            NSLog(@"[DIM-DIAG] FILE = NOT FOUND / NOT ACCESSIBLE");
            NSLog(@"[DIM-DIAG] ===== END =====");
            return;
        }

        NSDictionary *root =
            [NSDictionary dictionaryWithContentsOfFile:path];

        if (![root isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[DIM-DIAG] PLIST = INVALID OR UNREADABLE");
            NSLog(@"[DIM-DIAG] ===== END =====");
            return;
        }

        NSLog(@"[DIM-DIAG] PLIST = READ OK");

        NSDictionary *profile = root[@"ActiveProfile"];

        if (![profile isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[DIM-DIAG] ActiveProfile = MISSING / INVALID");
            NSLog(@"[DIM-DIAG] ===== END =====");
            return;
        }

        NSLog(@"[DIM-DIAG] ActiveProfile = FOUND");

        DIMCheckValue(profile, @"name");
        DIMCheckValue(profile, @"identifier");
        DIMCheckValue(profile, @"boardconfig");
        DIMCheckValue(profile, @"version");
        DIMCheckValue(profile, @"build");
        DIMCheckValue(profile, @"darwin");
        DIMCheckValue(profile, @"config_applied");
        DIMCheckValue(profile, @"ios_applied");

        NSLog(@"[DIM-DIAG] ===== END =====");
    }
}
