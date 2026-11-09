
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "DIMCatalogManager.h"

@interface DIMDeviceListController : PSListController
- (void)refreshCatalog;
@end

@implementation DIMDeviceListController

static NSString * const DIMDomain = @"com.dim.manager";

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];
}

- (PSSpecifier *)group:(NSString *)name {
    return [PSSpecifier preferenceSpecifierNamed:name
                                           target:nil
                                              set:nil
                                              get:nil
                                           detail:nil
                                             cell:PSGroupCell
                                             edit:nil];
}

- (PSSpecifier *)makeList:(NSString *)title
                      key:(NSString *)key
                   titles:(NSArray *)titles
                   values:(NSArray *)values
                  default:(id)defaultValue {

    PSSpecifier *specifier =
    [PSSpecifier preferenceSpecifierNamed:title
                                    target:self
                                       set:@selector(setPreferenceValue:specifier:)
                                       get:@selector(readPreferenceValue:)
                                    detail:@"PSListItemsController"
                                      cell:PSLinkListCell
                                      edit:nil];

    [specifier setProperty:key forKey:@"key"];
    [specifier setProperty:DIMDomain forKey:@"defaults"];
    [specifier setProperty:titles forKey:@"validTitles"];
    [specifier setProperty:values forKey:@"validValues"];
    [specifier setProperty:defaultValue forKey:@"default"];

    return specifier;
}

- (PSSpecifier *)statusSpecifier:(NSString *)text {
    PSSpecifier *specifier =
    [PSSpecifier preferenceSpecifierNamed:text
                                    target:nil
                                       set:nil
                                       get:nil
                                    detail:nil
                                      cell:PSStaticTextCell
                                      edit:nil];

    return specifier;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [NSMutableArray array];

        NSUserDefaults *prefs = [self prefs];

        NSString *family =
        [prefs stringForKey:@"DeviceFamily"] ?: @"iPhone";

        BOOL isIPad = [family isEqualToString:@"iPad"];

        NSString *osFamily = isIPad ? @"iPadOS" : @"iOS";

        DIMCatalogManager *catalog =
        [DIMCatalogManager sharedManager];

        [items addObject:[self group:@"CATALOG"]];

        PSSpecifier *refresh =
        [PSSpecifier preferenceSpecifierNamed:@"Refresh Catalog"
                                        target:self
                                           set:nil
                                           get:nil
                                        detail:nil
                                          cell:PSButtonCell
                                          edit:nil];

        [refresh setProperty:NSStringFromSelector(@selector(refreshCatalog))
                      forKey:@"action"];

        [items addObject:refresh];

        NSDate *lastUpdate = [catalog lastUpdateDate];

        NSString *dateText = @"Never updated";

        if (lastUpdate) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.dateStyle = NSDateFormatterMediumStyle;
            formatter.timeStyle = NSDateFormatterShortStyle;

            dateText = [formatter stringFromDate:lastUpdate];
        }

        [items addObject:
         [self statusSpecifier:
          [NSString stringWithFormat:@"Last update: %@", dateText]]];

        [items addObject:
         [self statusSpecifier:[catalog catalogStatus]]];

        [items addObject:[self group:@"DEVICE FAMILY"]];

        [items addObject:
         [self makeList:@"Device Family"
                    key:@"DeviceFamily"
                 titles:@[@"iPhone", @"iPad"]
                 values:@[@"iPhone", @"iPad"]
                default:@"iPhone"]];

        NSArray *devices = [catalog devicesForFamily:family];

        NSMutableArray *deviceTitles = [NSMutableArray array];
        NSMutableArray *deviceValues = [NSMutableArray array];

        for (NSDictionary *device in devices) {
            NSString *name = device[@"name"];
            NSString *identifier = device[@"identifier"];

            if (name && identifier) {
                [deviceTitles addObject:
                 [NSString stringWithFormat:@"%@ (%@)", name, identifier]];

                [deviceValues addObject:identifier];
            }
        }

        [items addObject:[self group:@"DEVICE MODEL"]];

        if (deviceValues.count > 0) {
            NSString *selectedModel =
            [prefs stringForKey:@"SelectedModel"];

            if (![deviceValues containsObject:selectedModel]) {
                selectedModel = deviceValues.firstObject;
            }

            [items addObject:
             [self makeList:@"Device Model"
                        key:@"SelectedModel"
                     titles:deviceTitles
                     values:deviceValues
                    default:selectedModel]];

            for (NSDictionary *device in devices) {
                if ([device[@"identifier"] isEqualToString:selectedModel]) {
                    [items addObject:
                     [self statusSpecifier:
                      [NSString stringWithFormat:@"ProductType: %@",
                       device[@"identifier"]]]];

                    if (device[@"boardconfig"]) {
                        [items addObject:
                         [self statusSpecifier:
                          [NSString stringWithFormat:@"Board: %@",
                           device[@"boardconfig"]]]];
                    }

                    if ([device[@"models"] isKindOfClass:[NSArray class]]) {
                        NSString *models =
                        [device[@"models"] componentsJoinedByString:@", "];

                        [items addObject:
                         [self statusSpecifier:
                          [NSString stringWithFormat:@"Model numbers: %@",
                           models]]];
                    }

                    break;
                }
            }
        } else {
            [items addObject:
             [self statusSpecifier:
              @"No cached devices. Tap Refresh Catalog."]];
        }

        [items addObject:[self group:@"OPERATING SYSTEM"]];

        NSArray *versions = [catalog versionsForFamily:family];

        NSMutableArray *versionTitles = [NSMutableArray array];
        NSMutableArray *versionValues = [NSMutableArray array];

        for (NSDictionary *version in versions) {
            NSString *number = version[@"version"] ?: @"";
            NSString *build = version[@"build"] ?: @"";

            NSString *title = number;

            if (build.length > 0) {
                title = [NSString stringWithFormat:@"%@ (%@)", number, build];
            }

            NSString *value =
            [NSString stringWithFormat:@"%@|%@", number, build];

            [versionTitles addObject:title];
            [versionValues addObject:value];
        }

        if (versionValues.count > 0) {
            NSString *selectedVersion =
            [prefs stringForKey:@"SelectedVersion"] ?: @"";

            NSString *selectedBuild =
            [prefs stringForKey:@"SelectedBuild"] ?: @"";

            NSString *selectedValue =
            [NSString stringWithFormat:@"%@|%@", selectedVersion, selectedBuild];

            if (![versionValues containsObject:selectedValue]) {
                selectedValue = versionValues.firstObject;
            }

            [items addObject:
             [self makeList:@"Operating System"
                        key:@"SelectedFirmware"
                     titles:versionTitles
                     values:versionValues
                    default:selectedValue]];
        } else {
            [items addObject:
             [self statusSpecifier:
              [NSString stringWithFormat:
               @"No cached %@ versions. Tap Refresh Catalog.",
               osFamily]]];
        }

        [items addObject:[self group:@"COMPATIBILITY"]];

        PSSpecifier *nonstandard =
        [PSSpecifier preferenceSpecifierNamed:@"Non-standard combinations"
                                        target:self
                                           set:@selector(setPreferenceValue:specifier:)
                                           get:@selector(readPreferenceValue:)
                                        detail:nil
                                          cell:PSSwitchCell
                                          edit:nil];

        [nonstandard setProperty:@"NonStandardCombinations" forKey:@"key"];
        [nonstandard setProperty:DIMDomain forKey:@"defaults"];
        [nonstandard setProperty:@NO forKey:@"default"];

        [items addObject:nonstandard];

        [items addObject:
         [self statusSpecifier:
          @"Catalog entries come from IPSW.info and AppleDB."]];

        _specifiers = items;
    }

    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];

    NSUserDefaults *prefs = [self prefs];

    if ([key isEqualToString:@"DeviceFamily"]) {
        if ([value isEqualToString:@"iPad"]) {
            [prefs setObject:@"iPad" forKey:@"DeviceFamily"];
            [prefs removeObjectForKey:@"SelectedModel"];
            [prefs removeObjectForKey:@"SelectedVersion"];
            [prefs removeObjectForKey:@"SelectedBuild"];
        } else {
            [prefs setObject:@"iPhone" forKey:@"DeviceFamily"];
            [prefs removeObjectForKey:@"SelectedModel"];
            [prefs removeObjectForKey:@"SelectedVersion"];
            [prefs removeObjectForKey:@"SelectedBuild"];
        }
    }

    if ([key isEqualToString:@"SelectedFirmware"] &&
        [value isKindOfClass:[NSString class]]) {

        NSArray *parts = [value componentsSeparatedByString:@"|"];

        if (parts.count >= 2) {
            [prefs setObject:parts[0] forKey:@"SelectedVersion"];

            if ([parts[1] length] > 0) {
                [prefs setObject:parts[1] forKey:@"SelectedBuild"];
            } else {
                [prefs removeObjectForKey:@"SelectedBuild"];
            }
        }
    }

    [prefs synchronize];

    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)refreshCatalog {
    [self showLoadingView];

    [[DIMCatalogManager sharedManager]
     refreshCatalogWithCompletion:^(BOOL success, NSString *message) {

        [self hideLoadingView];

        self->_specifiers = nil;
        [self reloadSpecifiers];

        UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:
         success ? @"Catalog Updated" : @"Catalog Update Failed"
                                             message:message
                                      preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:
         [UIAlertAction actionWithTitle:@"OK"
                                  style:UIAlertActionStyleDefault
                                handler:nil]];

        [self presentViewController:alert animated:YES completion:nil];
    }];
}

@end
