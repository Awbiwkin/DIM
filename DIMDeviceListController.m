
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "DIMCatalogManager.h"

static NSString * const DIMDomain = @"com.dim.manager";

@interface DIMDeviceListController : PSListController
- (void)refreshCatalog;
@end

@implementation DIMDeviceListController

#pragma mark - Preferences

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];
}

#pragma mark - Specifier Helpers

- (PSSpecifier *)makeGroup:(NSString *)title {
    return [PSSpecifier preferenceSpecifierNamed:title
                                           target:nil
                                              set:NULL
                                              get:NULL
                                           detail:nil
                                             cell:PSGroupCell
                                             edit:nil];
}

- (PSSpecifier *)makeStatus:(NSString *)title {
    return [PSSpecifier preferenceSpecifierNamed:title
                                           target:nil
                                              set:NULL
                                              get:NULL
                                           detail:nil
                                             cell:PSStaticTextCell
                                             edit:nil];
}

- (PSSpecifier *)makeList:(NSString *)title
                      key:(NSString *)key
                   titles:(NSArray *)titles
                   values:(NSArray *)values
                  default:(id)defaultValue {

    Class listController = NSClassFromString(@"PSListItemsController");

    PSSpecifier *specifier =
    [PSSpecifier preferenceSpecifierNamed:title
                                    target:self
                                       set:@selector(setPreferenceValue:specifier:)
                                       get:@selector(readPreferenceValue:)
                                    detail:listController
                                      cell:PSLinkListCell
                                      edit:nil];

    [specifier setProperty:key forKey:@"key"];
    [specifier setProperty:DIMDomain forKey:@"defaults"];
    [specifier setProperty:titles forKey:@"validTitles"];
    [specifier setProperty:values forKey:@"validValues"];
    [specifier setProperty:defaultValue forKey:@"default"];
    [specifier setProperty:@YES forKey:@"enabled"];

    return specifier;
}

#pragma mark - Catalog Information

- (NSString *)formattedUpdateDate {
    NSDate *date = [[DIMCatalogManager sharedManager] lastUpdateDate];

    if (![date isKindOfClass:[NSDate class]]) {
        return @"Never updated";
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;

    return [formatter stringFromDate:date];
}

#pragma mark - Refresh Button

- (void)refreshCatalog {
    if (self.presentedViewController) {
        return;
    }

    UIAlertController *loading =
    [UIAlertController alertControllerWithTitle:@"Updating Catalog"
                                        message:@"Connecting to IPSW.info and AppleDB..."
                                 preferredStyle:UIAlertControllerStyleAlert];

    [self presentViewController:loading animated:YES completion:nil];

    [[DIMCatalogManager sharedManager]
     refreshCatalogWithCompletion:^(BOOL success, NSString *message) {

        [loading dismissViewControllerAnimated:YES completion:^{

            self->_specifiers = nil;
            [self reloadSpecifiers];

            UIAlertController *result =
            [UIAlertController alertControllerWithTitle:
             (success ? @"Catalog Updated" : @"Update Failed")
                                                 message:message
                                          preferredStyle:UIAlertControllerStyleAlert];

            [result addAction:
             [UIAlertAction actionWithTitle:@"OK"
                                      style:UIAlertActionStyleDefault
                                    handler:nil]];

            [self presentViewController:result animated:YES completion:nil];
        }];
    }];
}

#pragma mark - Build Interface

- (NSArray *)specifiers {
    if (_specifiers) {
        return _specifiers;
    }

    NSMutableArray *items = [NSMutableArray array];

    NSUserDefaults *prefs = [self prefs];
    DIMCatalogManager *catalog = [DIMCatalogManager sharedManager];

    NSString *family =
    [prefs stringForKey:@"DeviceFamily"] ?: @"iPhone";

    if (![family isEqualToString:@"iPad"]) {
        family = @"iPhone";
    }

    NSString *osFamily =
    [family isEqualToString:@"iPad"] ? @"iPadOS" : @"iOS";

    // CATALOG

    [items addObject:[self makeGroup:@"CATALOG"]];

    PSSpecifier *refresh =
    [PSSpecifier preferenceSpecifierNamed:@"Refresh Catalog"
                                    target:self
                                       set:NULL
                                       get:NULL
                                    detail:nil
                                      cell:PSButtonCell
                                      edit:nil];

    refresh.target = self;
    refresh.buttonAction = @selector(refreshCatalog);

    [refresh setProperty:@YES forKey:@"enabled"];

    [items addObject:refresh];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Last update: %@",
       [self formattedUpdateDate]]]];

    [items addObject:
     [self makeStatus:[catalog catalogStatus]]];

    // DEVICE FAMILY

    [items addObject:[self makeGroup:@"DEVICE FAMILY"]];

    [items addObject:
     [self makeList:@"Device Family"
                key:@"DeviceFamily"
             titles:@[@"iPhone", @"iPad"]
             values:@[@"iPhone", @"iPad"]
            default:@"iPhone"]];

    // DEVICE MODEL

    [items addObject:[self makeGroup:@"DEVICE MODEL"]];

    NSArray *devices = [catalog devicesForFamily:family];

    NSMutableArray *deviceTitles = [NSMutableArray array];
    NSMutableArray *deviceValues = [NSMutableArray array];

    for (NSDictionary *device in devices) {
        if (![device isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *name = device[@"name"];
        NSString *identifier = device[@"identifier"];

        if (![name isKindOfClass:[NSString class]] ||
            ![identifier isKindOfClass:[NSString class]]) {
            continue;
        }

        [deviceTitles addObject:
         [NSString stringWithFormat:@"%@ (%@)", name, identifier]];

        [deviceValues addObject:identifier];
    }

    NSString *selectedModel = [prefs stringForKey:@"SelectedModel"];

    if (deviceValues.count > 0) {

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

            if (![device[@"identifier"] isEqualToString:selectedModel]) {
                continue;
            }

            [items addObject:
             [self makeStatus:
              [NSString stringWithFormat:@"ProductType: %@",
               device[@"identifier"]]]];

            NSString *board = device[@"boardconfig"];

            if ([board isKindOfClass:[NSString class]] && board.length > 0) {
                [items addObject:
                 [self makeStatus:
                  [NSString stringWithFormat:@"Board: %@", board]]];
            }

            NSArray *models = device[@"models"];

            if ([models isKindOfClass:[NSArray class]] && models.count > 0) {
                [items addObject:
                 [self makeStatus:
                  [NSString stringWithFormat:@"Model numbers: %@",
                   [models componentsJoinedByString:@", "]]]];
            }

            break;
        }

    } else {

        [items addObject:
         [self makeStatus:
          @"No cached devices. Tap Refresh Catalog."]];
    }

    // OPERATING SYSTEM

    [items addObject:[self makeGroup:@"OPERATING SYSTEM"]];

    NSArray *versions = [catalog versionsForFamily:family];

    NSMutableArray *versionTitles = [NSMutableArray array];
    NSMutableArray *versionValues = [NSMutableArray array];

    for (NSDictionary *version in versions) {

        if (![version isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *number = version[@"version"];
        NSString *build = version[@"build"];

        if (![number isKindOfClass:[NSString class]] ||
            number.length == 0) {
            continue;
        }

        if (![build isKindOfClass:[NSString class]]) {
            build = @"";
        }

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
         [self makeStatus:
          [NSString stringWithFormat:
           @"No cached %@ versions. Tap Refresh Catalog.",
           osFamily]]];
    }

    // COMPATIBILITY

    [items addObject:[self makeGroup:@"COMPATIBILITY"]];

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
     [self makeStatus:
      @"Catalog data is provided by IPSW.info and AppleDB."]];

    _specifiers = [items copy];

    return _specifiers;
}

#pragma mark - Save Preferences

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {

    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];

    NSUserDefaults *prefs = [self prefs];

    if ([key isEqualToString:@"DeviceFamily"]) {

        [prefs removeObjectForKey:@"SelectedModel"];
        [prefs removeObjectForKey:@"SelectedVersion"];
        [prefs removeObjectForKey:@"SelectedBuild"];
        [prefs removeObjectForKey:@"SelectedFirmware"];
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

@end
