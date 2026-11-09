#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

static NSString * const DIMDomain = @"com.dim.manager";

@interface DIMRootListController : PSListController
@end

@implementation DIMRootListController

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];
}

- (NSString *)labelForSpecifier:(PSSpecifier *)specifier {
    NSString *label = [specifier propertyForKey:@"label"];

    if (![label isKindOfClass:NSString.class] || !label.length) {
        label = [specifier name];
    }

    return [label isKindOfClass:NSString.class] ? label : @"";
}

- (NSArray *)specifiers {
    if (_specifiers) {
        return _specifiers;
    }

    NSArray *allSpecifiers =
        [self loadSpecifiersFromPlistName:@"Root"
                                   target:self];

    NSUserDefaults *defaults = [self prefs];

    BOOL dimEnabled = YES;

    if ([defaults objectForKey:@"Enabled"] != nil) {
        dimEnabled = [defaults boolForKey:@"Enabled"];
    }

    BOOL deviceEnabled = [defaults boolForKey:@"DeviceEnabled"];

    NSMutableArray *filtered = [NSMutableArray array];

    for (PSSpecifier *specifier in allSpecifiers) {
        NSString *key = [specifier propertyForKey:@"key"];
        NSString *label = [self labelForSpecifier:specifier];

        // Главный переключатель и GENERAL показываются всегда.
        if ([key isEqualToString:@"Enabled"] ||
            [label isEqualToString:@"GENERAL"]) {
            [filtered addObject:specifier];
            continue;
        }

        // Если DIM выключен — больше ничего не показываем.
        if (!dimEnabled) {
            continue;
        }

        // Группа DEVICE и ссылка на её настройки
        // должны появляться только при включённом Device Identity.
        if ([label isEqualToString:@"DEVICE"] ||
            [label isEqualToString:@"Configure Device Identity"]) {

            if (deviceEnabled) {
                [filtered addObject:specifier];
            }

            continue;
        }

        // Все остальные модули остаются видимыми.
        [filtered addObject:specifier];
    }

    _specifiers = [filtered copy];
    return _specifiers;
}

- (void)setPreferenceValue:(id)value
                 specifier:(PSSpecifier *)specifier {

    [super setPreferenceValue:value specifier:specifier];

    [[self prefs] synchronize];

    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
