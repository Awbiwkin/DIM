
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface DIMRootListController : PSListController
@end

@implementation DIMRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *allSpecifiers =
            [self loadSpecifiersFromPlistName:@"Root"
                                       target:self];

        NSUserDefaults *defaults =
            [[NSUserDefaults alloc]
                initWithSuiteName:@"com.dim.manager"];

        BOOL dimEnabled = YES;

        if ([defaults objectForKey:@"Enabled"] != nil) {
            dimEnabled = [defaults boolForKey:@"Enabled"];
        }

        BOOL deviceEnabled =
            [defaults boolForKey:@"DeviceEnabled"];

        NSMutableArray *filtered =
            [NSMutableArray array];

        for (PSSpecifier *specifier in allSpecifiers) {
            NSString *key =
                [specifier propertyForKey:@"key"];

            NSString *label =
                [specifier name];

            // DIM выключен: оставляем только GENERAL
            // и главный переключатель.
            if (!dimEnabled) {
                if ([key isEqualToString:@"Enabled"] ||
                    [label isEqualToString:@"GENERAL"]) {
                    [filtered addObject:specifier];
                }

                continue;
            }

            // Настройки Device Identity доступны
            // только при включённом модуле.
            if ([label isEqualToString:@"DEVICE"] ||
                [label isEqualToString:@"Device Identity Settings"]) {
                if (deviceEnabled) {
                    [filtered addObject:specifier];
                }

                continue;
            }

            [filtered addObject:specifier];
        }

        _specifiers = filtered;
    }

    return _specifiers;
}

- (void)setPreferenceValue:(id)value
                 specifier:(PSSpecifier *)specifier {

    [super setPreferenceValue:value
                    specifier:specifier];

    NSUserDefaults *defaults =
        [[NSUserDefaults alloc]
            initWithSuiteName:@"com.dim.manager"];

    [defaults synchronize];

    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
