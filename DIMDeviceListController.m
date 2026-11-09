
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "DIMCatalogManager.h"

static NSString * const DIMDomain = @"com.dim.manager";
static NSString * const DIMActiveProfileKey = @"ActiveProfile";

@interface DIMAppProfilesController : UITableViewController
@end

@interface DIMPickerController : UITableViewController <UISearchBarDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredItems;
@property (nonatomic, copy) NSString *pickerTitle;
@property (nonatomic, copy) NSString *displayKey;
@property (nonatomic, copy) NSString *valueKey;
@property (nonatomic, copy) void (^selectionHandler)(NSDictionary *);
@property (nonatomic, strong) UISearchBar *searchBar;
@end

@implementation DIMPickerController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = self.pickerTitle;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search";
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;

    self.tableView.tableHeaderView = self.searchBar;
    self.filteredItems = self.items ?: @[];

    [self.tableView registerClass:UITableViewCell.class
           forCellReuseIdentifier:@"DIMPickerCell"];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    if (!text.length) {
        self.filteredItems = self.items ?: @[];
    } else {
        NSPredicate *predicate =
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *bindings) {
            NSString *name = [item[self.displayKey] isKindOfClass:NSString.class]
                ? item[self.displayKey] : @"";
            NSString *value = [item[self.valueKey] isKindOfClass:NSString.class]
                ? item[self.valueKey] : @"";
            NSString *build = [item[@"build"] isKindOfClass:NSString.class]
                ? item[@"build"] : @"";

            return [name localizedCaseInsensitiveContainsString:text] ||
                   [value localizedCaseInsensitiveContainsString:text] ||
                   [build localizedCaseInsensitiveContainsString:text];
        }];

        self.filteredItems = [self.items filteredArrayUsingPredicate:predicate];
    }

    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredItems.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"%lu results",
            (unsigned long)self.filteredItems.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    UITableViewCell *cell =
    [tableView dequeueReusableCellWithIdentifier:@"DIMPickerCell"
                                    forIndexPath:indexPath];

    NSDictionary *item = self.filteredItems[indexPath.row];

    cell.textLabel.text = item[self.displayKey];
    cell.textLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if ([item[@"is_beta"] boolValue]) {
        cell.textLabel.textColor = UIColor.systemOrangeColor;
    } else if ([item[@"compatible"] respondsToSelector:@selector(boolValue)] &&
               ![item[@"compatible"] boolValue]) {
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
    } else {
        cell.textLabel.textColor = UIColor.labelColor;
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {

    NSDictionary *item = self.filteredItems[indexPath.row];

    if (self.selectionHandler) {
        self.selectionHandler(item);
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

@interface DIMDeviceListController : PSListController
- (void)refreshCatalog;
- (void)openFamilyPicker;
- (void)openDevicePicker;
- (void)openRegionPicker;
- (void)openModelNumberPicker;
- (void)openFirmwarePicker;
- (void)openApplicationPicker;
- (void)applyConfig;
- (void)applyIOS;
- (void)applyAll;
- (void)checkActiveProfile;
@end

@implementation DIMDeviceListController

#pragma mark - Preferences

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];
}

- (void)reloadDIMInterface {
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadDIMInterface];
}

#pragma mark - Current Device

- (NSString *)currentDeviceName {
    NSString *identifier = [DIMCatalogManager currentDeviceIdentifier];

    NSDictionary *device =
    [[DIMCatalogManager sharedManager] deviceForIdentifier:identifier];

    if ([device[@"name"] isKindOfClass:NSString.class]) {
        return device[@"name"];
    }

    if ([identifier isEqualToString:@"iPhone8,1"]) return @"iPhone 6s";
    if ([identifier isEqualToString:@"iPhone8,2"]) return @"iPhone 6s Plus";

    return identifier.length ? identifier : @"Unknown Device";
}

- (NSString *)selectedFamily {
    NSString *family = [[self prefs] stringForKey:@"DeviceFamily"];

    if (!family.length) {
        family = [DIMCatalogManager currentDeviceFamily];
        [[self prefs] setObject:family forKey:@"DeviceFamily"];
        [[self prefs] synchronize];
    }

    return family;
}

- (NSString *)selectedModel {
    NSString *model = [[self prefs] stringForKey:@"SelectedModel"];

    if (model.length) return model;

    if ([[self selectedFamily] isEqualToString:
         [DIMCatalogManager currentDeviceFamily]]) {

        model = [DIMCatalogManager currentDeviceIdentifier];

        if (model.length) {
            [[self prefs] setObject:model forKey:@"SelectedModel"];
            [[self prefs] synchronize];
            return model;
        }
    }

    return @"";
}

- (NSDictionary *)selectedDevice {
    NSString *identifier = [self selectedModel];
    if (!identifier.length) return nil;

    return [[DIMCatalogManager sharedManager] deviceForIdentifier:identifier];
}

- (NSString *)selectedDeviceName {
    NSString *name = [self selectedDevice][@"name"];
    if (name.length) return name;

    NSString *identifier = [self selectedModel];
    return identifier.length ? identifier : @"Not selected";
}

- (NSString *)boardConfiguration {
    NSString *board = [self selectedDevice][@"boardconfig"];
    return board.length ? board : @"";
}

- (NSArray<NSDictionary *> *)modelVariants {
    id variants = [self selectedDevice][@"model_variants"];

    if (![variants isKindOfClass:NSArray.class]) return @[];

    NSMutableArray *result = [NSMutableArray array];

    for (id entry in variants) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;

        NSString *modelNumber = [entry[@"model"] isKindOfClass:NSString.class]
            ? entry[@"model"] : nil;

        NSString *region = [entry[@"region"] isKindOfClass:NSString.class]
            ? entry[@"region"] : nil;

        if (!modelNumber.length) continue;

        [result addObject:@{
            @"model": modelNumber,
            @"region": region ?: @""
        }];
    }

    return result;
}

- (NSArray<NSString *> *)availableRegions {
    NSMutableSet *regions = [NSMutableSet set];

    for (NSDictionary *variant in [self modelVariants]) {
        NSString *region = variant[@"region"];
        if (region.length) [regions addObject:region];
    }

    return [[regions allObjects]
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSString *)selectedRegion {
    return [[self prefs] stringForKey:@"SelectedRegion"] ?: @"";
}

- (NSString *)selectedModelNumber {
    return [[self prefs] stringForKey:@"SelectedModelNumber"] ?: @"";
}

- (NSArray<NSString *> *)modelNumbersForSelectedRegion {
    NSString *selectedRegion = [self selectedRegion];
    NSMutableSet *numbers = [NSMutableSet set];

    for (NSDictionary *variant in [self modelVariants]) {
        NSString *region = variant[@"region"];
        NSString *modelNumber = variant[@"model"];

        if (!modelNumber.length) continue;

        if (selectedRegion.length) {
            if ([region isEqualToString:selectedRegion]) {
                [numbers addObject:modelNumber];
            }
        } else if (!region.length) {
            [numbers addObject:modelNumber];
        }
    }

    return [[numbers allObjects]
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSString *)regionDisplayName {
    NSString *region = [self selectedRegion];
    return region.length ? region : @"Not selected";
}

- (NSString *)modelNumberDisplayName {
    NSString *number = [self selectedModelNumber];
    return number.length ? number : @"Not selected";
}

#pragma mark - Active Profile

- (NSDictionary *)activeProfile {
    id profile = [[self prefs] dictionaryForKey:DIMActiveProfileKey];
    return [profile isKindOfClass:NSDictionary.class] ? profile : @{};
}

- (NSString *)profileValue:(NSString *)key {
    id value = [self activeProfile][key];

    if ([value isKindOfClass:NSString.class] && [value length]) {
        return value;
    }

    return @"Not recorded";
}

- (NSString *)darwinVersionForIOS:(NSString *)version {
    if (!version.length) return nil;

    NSArray *parts = [version componentsSeparatedByString:@"."];
    if (parts.count == 0) return nil;

    NSInteger major = [parts[0] integerValue];
    NSInteger minor = parts.count > 1 ? [parts[1] integerValue] : 0;

    if (major < 12 || major > 30 || minor < 0) return nil;

    // iOS 18.x = Darwin 24.x, iOS 17.x = Darwin 23.x.
    NSInteger darwinMajor = major + 6;

    return [NSString stringWithFormat:@"%ld.%ld.0",
            (long)darwinMajor, (long)minor];
}

- (NSMutableDictionary *)profileForCurrentSelection {
    NSDictionary *device = [self selectedDevice];

    NSString *identifier = [self selectedModel];
    NSString *name = [device[@"name"] isKindOfClass:NSString.class]
        ? device[@"name"] : @"";
    NSString *board = [device[@"boardconfig"] isKindOfClass:NSString.class]
        ? device[@"boardconfig"] : @"";

    if (!identifier.length || !name.length || !board.length) {
        return nil;
    }

    return [@{
        @"name": name,
        @"identifier": identifier,
        @"boardconfig": board,
        @"model_number": [self selectedModelNumber],
        @"region": [self selectedRegion]
    } mutableCopy];
}

- (BOOL)profileHasConfig:(NSDictionary *)profile {
    return [profile[@"config_applied"] boolValue] &&
           [profile[@"name"] isKindOfClass:NSString.class] &&
           [profile[@"name"] length] &&
           [profile[@"identifier"] isKindOfClass:NSString.class] &&
           [profile[@"identifier"] length] &&
           [profile[@"boardconfig"] isKindOfClass:NSString.class] &&
           [profile[@"boardconfig"] length];
}

- (BOOL)profileHasIOS:(NSDictionary *)profile {
    return [profile[@"ios_applied"] boolValue] &&
           [profile[@"version"] isKindOfClass:NSString.class] &&
           [profile[@"version"] length] &&
           [profile[@"build"] isKindOfClass:NSString.class] &&
           [profile[@"build"] length] &&
           [profile[@"darwin"] isKindOfClass:NSString.class] &&
           [profile[@"darwin"] length];
}

- (BOOL)isActiveProfileValid {
    NSDictionary *profile = [self activeProfile];
    return [self profileHasConfig:profile] && [self profileHasIOS:profile];
}

- (void)saveActiveProfile:(NSDictionary *)profile {
    NSUserDefaults *prefs = [self prefs];
    [prefs setObject:profile forKey:DIMActiveProfileKey];
    [prefs synchronize];
}

#pragma mark - Apply Actions

- (void)applyConfig {
    NSMutableDictionary *config = [self profileForCurrentSelection];

    if (!config) {
        [self showMessage:
         @"The selected device is missing its name, ProductType or BoardConfig. The profile was not written."
                    title:@"Cannot Apply Config"];
        return;
    }

    NSDictionary *oldProfile = [self activeProfile];

    // Keep the already-applied OS only when it belongs to the same device.
    if ([oldProfile[@"identifier"] isEqualToString:config[@"identifier"]]) {
        if ([self profileHasIOS:oldProfile]) {
            config[@"version"] = oldProfile[@"version"];
            config[@"build"] = oldProfile[@"build"];
            config[@"darwin"] = oldProfile[@"darwin"];
            config[@"ios_applied"] = @YES;
        }
    }

    config[@"config_applied"] = @YES;

    [self saveActiveProfile:config];
    [self reloadDIMInterface];

    [self showMessage:
     [NSString stringWithFormat:@"%@ · %@\nBoardConfig: %@",
      config[@"name"], config[@"identifier"], config[@"boardconfig"]]
                title:@"Configuration Written"];
}

- (void)applyIOS {
    NSString *version = [[self prefs] stringForKey:@"SelectedVersion"];
    NSString *build = [[self prefs] stringForKey:@"SelectedBuild"];
    NSString *darwin = [self darwinVersionForIOS:version];

    if (!version.length || !build.length || !darwin.length) {
        [self showMessage:
         @"Choose a valid iOS / iPadOS version and build first."
                    title:@"Cannot Apply iOS"];
        return;
    }

    NSMutableDictionary *profile = [[self activeProfile] mutableCopy];

    NSString *identifier = [self selectedModel];

    // Do not attach an old device configuration to a different selection.
    if (![profile[@"identifier"] isEqualToString:identifier]) {
        profile = [NSMutableDictionary dictionary];
    }

    profile[@"version"] = version;
    profile[@"build"] = build;
    profile[@"darwin"] = darwin;
    profile[@"ios_applied"] = @YES;

    [self saveActiveProfile:profile];
    [self reloadDIMInterface];

    [self showMessage:
     [NSString stringWithFormat:@"iOS: %@\nBuild: %@\nDarwin: %@",
      version, build, darwin]
                title:@"iOS Written"];
}

- (void)applyAll {
    NSMutableDictionary *profile = [self profileForCurrentSelection];

    if (!profile) {
        [self showMessage:
         @"The selected device is missing its name, ProductType or BoardConfig."
                    title:@"Cannot Apply All"];
        return;
    }

    NSString *version = [[self prefs] stringForKey:@"SelectedVersion"];
    NSString *build = [[self prefs] stringForKey:@"SelectedBuild"];
    NSString *darwin = [self darwinVersionForIOS:version];

    if (!version.length || !build.length || !darwin.length) {
        [self showMessage:
         @"Choose a valid iOS / iPadOS version and build first."
                    title:@"Cannot Apply All"];
        return;
    }

    profile[@"version"] = version;
    profile[@"build"] = build;
    profile[@"darwin"] = darwin;
    profile[@"config_applied"] = @YES;
    profile[@"ios_applied"] = @YES;

    [self saveActiveProfile:profile];
    [self reloadDIMInterface];

    [self showMessage:
     [NSString stringWithFormat:@"%@ · %@\niOS: %@ · %@",
      profile[@"name"], profile[@"identifier"], version, build]
                title:@"Profile Applied"];
}

- (void)checkActiveProfile {
    NSDictionary *profile = [self activeProfile];

    BOOL configOK = [self profileHasConfig:profile];
    BOOL iosOK = [self profileHasIOS:profile];
    BOOL allOK = configOK && iosOK;

    [self reloadDIMInterface];

    NSString *message = [NSString stringWithFormat:
                         @"Configuration: %@\niOS: %@\n\nActiveProfile: %@",
                         configOK ? @"OK" : @"NO",
                         iosOK ? @"OK" : @"NO",
                         allOK ? @"OK" : @"INCOMPLETE"];

    [self showMessage:message title:(allOK ? @"Check: OK" : @"Check: NO")];
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

- (PSSpecifier *)makeButton:(NSString *)title action:(SEL)action {
    PSSpecifier *specifier =
    [PSSpecifier preferenceSpecifierNamed:title
                                    target:self
                                       set:NULL
                                       get:NULL
                                    detail:nil
                                      cell:PSButtonCell
                                      edit:nil];

    specifier.target = self;
    specifier.buttonAction = action;

    return specifier;
}

- (PSSpecifier *)makeSwitch:(NSString *)title
                        key:(NSString *)key
              defaultValue:(BOOL)defaultValue {

    PSSpecifier *specifier =
    [PSSpecifier preferenceSpecifierNamed:title
                                    target:self
                                       set:@selector(setPreferenceValue:specifier:)
                                       get:@selector(readPreferenceValue:)
                                    detail:nil
                                      cell:PSSwitchCell
                                      edit:nil];

    [specifier setProperty:key forKey:@"key"];
    [specifier setProperty:DIMDomain forKey:@"defaults"];
    [specifier setProperty:@(defaultValue) forKey:@"default"];

    return specifier;
}

#pragma mark - Application Scope

- (void)openApplicationPicker {
    DIMAppProfilesController *controller =
    [[DIMAppProfilesController alloc]
        initWithStyle:UITableViewStyleInsetGrouped];

    controller.title = @"Choose Applications";

    [self.navigationController pushViewController:controller animated:YES];
}

#pragma mark - Picker Navigation

- (void)presentPickerWithTitle:(NSString *)title
                         items:(NSArray<NSDictionary *> *)items
                    displayKey:(NSString *)displayKey
                      valueKey:(NSString *)valueKey
                      selected:(void (^)(NSDictionary *))selection {

    DIMPickerController *picker =
    [[DIMPickerController alloc] initWithStyle:UITableViewStyleInsetGrouped];

    picker.pickerTitle = title;
    picker.items = items ?: @[];
    picker.displayKey = displayKey;
    picker.valueKey = valueKey;
    picker.selectionHandler = selection;

    [self.navigationController pushViewController:picker animated:YES];
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert =
    [UIAlertController alertControllerWithTitle:title
                                        message:message
                                 preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:
     [UIAlertAction actionWithTitle:@"OK"
                              style:UIAlertActionStyleDefault
                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Family Picker

- (void)openFamilyPicker {
    NSArray *families = @[
        @{@"name": @"iPhone", @"value": @"iPhone"},
        @{@"name": @"iPad", @"value": @"iPad"}
    ];

    __weak typeof(self) weakSelf = self;

    [self presentPickerWithTitle:@"Device Family"
                           items:families
                      displayKey:@"name"
                        valueKey:@"value"
                        selected:^(NSDictionary *item) {

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        NSString *family = item[@"value"];
        [[self prefs] setObject:family forKey:@"DeviceFamily"];

        if ([[DIMCatalogManager currentDeviceFamily] isEqualToString:family]) {
            [[self prefs] setObject:[DIMCatalogManager currentDeviceIdentifier]
                             forKey:@"SelectedModel"];
        } else {
            [[self prefs] removeObjectForKey:@"SelectedModel"];
        }

        [[self prefs] removeObjectForKey:@"SelectedRegion"];
        [[self prefs] removeObjectForKey:@"SelectedModelNumber"];
        [[self prefs] removeObjectForKey:@"SelectedVersion"];
        [[self prefs] removeObjectForKey:@"SelectedBuild"];

        [[self prefs] synchronize];
        [self reloadDIMInterface];
    }];
}

#pragma mark - Device Picker

- (void)openDevicePicker {
    NSArray *devices =
    [[DIMCatalogManager sharedManager] devicesForFamily:[self selectedFamily]];

    NSMutableArray *items = [NSMutableArray array];

    for (NSDictionary *device in devices) {
        NSString *name = device[@"name"];
        NSString *identifier = device[@"identifier"];

        if (!name.length || !identifier.length) continue;

        NSString *board = device[@"boardconfig"] ?: @"Board unknown";

        [items addObject:@{
            @"name": [NSString stringWithFormat:@"%@ · %@",
                      name, identifier],
            @"value": identifier,
            @"board": board
        }];
    }

    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];

    __weak typeof(self) weakSelf = self;

    [self presentPickerWithTitle:@"Select Device"
                           items:items
                      displayKey:@"name"
                        valueKey:@"value"
                        selected:^(NSDictionary *item) {

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        NSString *identifier = item[@"value"];

        [[self prefs] setObject:identifier forKey:@"SelectedModel"];
        [[self prefs] removeObjectForKey:@"SelectedRegion"];
        [[self prefs] removeObjectForKey:@"SelectedModelNumber"];
        [[self prefs] removeObjectForKey:@"SelectedVersion"];
        [[self prefs] removeObjectForKey:@"SelectedBuild"];
        [[self prefs] synchronize];

        [self reloadDIMInterface];

        [[DIMCatalogManager sharedManager]
         refreshFirmwaresForDevice:identifier
         completion:^(BOOL success, NSString *message) {
            [self reloadDIMInterface];
        }];
    }];
}

#pragma mark - Region Picker

- (void)openRegionPicker {
    NSArray<NSString *> *regions = [self availableRegions];

    if (regions.count == 0) {
        [self showMessage:
         @"The catalog does not provide region information for this device. No country mapping will be guessed."
                    title:@"Regions Unavailable"];
        return;
    }

    NSMutableArray *items = [NSMutableArray array];

    for (NSString *region in regions) {
        [items addObject:@{@"name": region, @"value": region}];
    }

    __weak typeof(self) weakSelf = self;

    [self presentPickerWithTitle:@"Select Region"
                           items:items
                      displayKey:@"name"
                        valueKey:@"value"
                        selected:^(NSDictionary *item) {

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        [[self prefs] setObject:item[@"value"] forKey:@"SelectedRegion"];
        [[self prefs] removeObjectForKey:@"SelectedModelNumber"];
        [[self prefs] synchronize];

        [self reloadDIMInterface];
    }];
}

#pragma mark - Model Number Picker

- (void)openModelNumberPicker {
    if (![self selectedModel].length) {
        [self showMessage:@"Select a device first." title:@"No Device"];
        return;
    }

    NSArray<NSString *> *numbers = [self modelNumbersForSelectedRegion];

    if (numbers.count == 0) {
        NSString *message = [self availableRegions].count
            ? @"Choose a region first. There are no model numbers for the selected region."
            : @"The catalog does not provide model-number variants for this device.";

        [self showMessage:message title:@"Model Numbers Unavailable"];
        return;
    }

    NSMutableArray *items = [NSMutableArray array];

    for (NSString *number in numbers) {
        [items addObject:@{@"name": number, @"value": number}];
    }

    __weak typeof(self) weakSelf = self;

    [self presentPickerWithTitle:@"Select Model Number"
                           items:items
                      displayKey:@"name"
                        valueKey:@"value"
                        selected:^(NSDictionary *item) {

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        [[self prefs] setObject:item[@"value"] forKey:@"SelectedModelNumber"];
        [[self prefs] synchronize];

        [self reloadDIMInterface];
    }];
}

#pragma mark - Firmware Picker

- (void)openFirmwarePicker {
    NSString *identifier = [self selectedModel];

    if (!identifier.length) {
        [self showMessage:@"Select a device first." title:@"No Device"];
        return;
    }

    BOOL showBetas = [[self prefs] boolForKey:@"ShowBetaBuilds"];
    BOOL allowIncompatible =
    [[self prefs] boolForKey:@"NonStandardCombinations"];

    NSArray *builds =
    [[DIMCatalogManager sharedManager]
     buildsForDevice:identifier
     includeBetas:showBetas
     allowIncompatible:allowIncompatible];

    NSMutableArray *items = [NSMutableArray array];

    for (NSDictionary *firmware in builds) {
        NSString *version = firmware[@"version"];
        NSString *build = firmware[@"build"];

        if (!version.length || !build.length) continue;

        NSMutableArray *labels = [NSMutableArray array];

        if ([firmware[@"is_beta"] boolValue]) [labels addObject:@"BETA"];
        if (![firmware[@"compatible"] boolValue]) [labels addObject:@"NON-STANDARD"];

        if ([firmware[@"signed"] respondsToSelector:@selector(boolValue)]) {
            [labels addObject:
             ([firmware[@"signed"] boolValue] ? @"SIGNED" : @"UNSIGNED")];
        }

        NSString *suffix = labels.count
            ? [NSString stringWithFormat:@" · %@",
               [labels componentsJoinedByString:@" · "]]
            : @"";

        NSMutableDictionary *entry = [firmware mutableCopy];
        entry[@"name"] = [NSString stringWithFormat:@"%@ (%@)%@",
                          version, build, suffix];
        entry[@"value"] = version;

        [items addObject:entry];
    }

    if (items.count == 0) {
        [self showMessage:
         @"No builds match the current filters. Enable beta builds or non-standard combinations, or refresh the catalog."
                    title:@"No Builds"];
        return;
    }

    __weak typeof(self) weakSelf = self;

    [self presentPickerWithTitle:@"Select iOS / iPadOS Build"
                           items:items
                      displayKey:@"name"
                        valueKey:@"value"
                        selected:^(NSDictionary *item) {

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        [[self prefs] setObject:item[@"value"] forKey:@"SelectedVersion"];
        [[self prefs] setObject:item[@"build"] forKey:@"SelectedBuild"];
        [[self prefs] setObject:item[@"is_beta"] ?: @NO
                         forKey:@"SelectedBuildIsBeta"];
        [[self prefs] setObject:item[@"compatible"] ?: @NO
                         forKey:@"SelectedBuildCompatible"];

        [[self prefs] synchronize];
        [self reloadDIMInterface];
    }];
}

#pragma mark - Catalog Refresh

- (NSString *)formattedUpdateDate {
    NSDate *date = [[DIMCatalogManager sharedManager] lastUpdateDate];

    if (![date isKindOfClass:NSDate.class]) return @"Never";

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;

    return [formatter stringFromDate:date];
}

- (void)refreshCatalog {
    UIAlertController *loading =
    [UIAlertController alertControllerWithTitle:@"Updating Catalog"
                                        message:@"Loading IPSW.info and AppleDB databases..."
                                 preferredStyle:UIAlertControllerStyleAlert];

    [self presentViewController:loading animated:YES completion:nil];

    [[DIMCatalogManager sharedManager]
     refreshCatalogWithCompletion:^(BOOL success, NSString *message) {

        NSString *selectedModel = [self selectedModel];

        void (^finish)(NSString *) = ^(NSString *firmwareMessage) {
            [loading dismissViewControllerAnimated:YES completion:^{

                [self reloadDIMInterface];

                NSString *fullMessage = message ?: @"Catalog refresh finished.";

                if (firmwareMessage.length) {
                    fullMessage = [fullMessage stringByAppendingFormat:
                                   @"\n\n%@", firmwareMessage];
                }

                [self showMessage:fullMessage
                            title:(success ? @"Catalog Updated" : @"Catalog Update")];
            }];
        };

        if (success && selectedModel.length) {
            [[DIMCatalogManager sharedManager]
             refreshFirmwaresForDevice:selectedModel
             completion:^(BOOL firmwareSuccess, NSString *firmwareMessage) {
                finish(firmwareMessage);
            }];
        } else {
            finish(nil);
        }
    }];
}

#pragma mark - Interface

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;

    NSMutableArray *items = [NSMutableArray array];

    DIMCatalogManager *catalog = [DIMCatalogManager sharedManager];
    NSUserDefaults *prefs = [self prefs];

    NSString *model = [self selectedModel];
    NSDictionary *active = [self activeProfile];

    NSDictionary *statistics = [catalog catalogStatistics];

    [items addObject:[self makeGroup:@"CURRENT DEVICE"]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"%@ • %@",
       [self currentDeviceName],
       [DIMCatalogManager currentDeviceIdentifier]]]];

    [items addObject:[self makeGroup:@"SPOOFED DEVICE"]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"%@ • %@ • iOS %@",
       [self profileValue:@"name"],
       [self profileValue:@"identifier"],
       [self profileValue:@"version"]]]];

    NSString *checkText = [self isActiveProfileValid]
        ? @"Check status: OK"
        : @"Check status: NO";

    [items addObject:[self makeStatus:checkText]];

    [items addObject:
     [self makeButton:@"Check"
               action:@selector(checkActiveProfile)]];

    [items addObject:[self makeGroup:@"SELECTED CONFIGURATION"]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"%@ • %@",
       [self selectedDeviceName],
       model.length ? model : @"Not selected"]]];

    NSString *board = [self boardConfiguration];
    NSString *modelNumber = [self selectedModelNumber];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"%@ • %@",
       board.length ? board : @"BoardConfig unavailable",
       modelNumber.length ? modelNumber : @"Model number not selected"]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Region: %@",
       [self regionDisplayName]]]];

    [items addObject:
     [self makeButton:@"Choose Device Family"
               action:@selector(openFamilyPicker)]];

    [items addObject:
     [self makeButton:@"Choose Device Model"
               action:@selector(openDevicePicker)]];

    [items addObject:
     [self makeButton:@"Choose Region"
               action:@selector(openRegionPicker)]];

    [items addObject:
     [self makeButton:@"Choose Model Number"
               action:@selector(openModelNumberPicker)]];

    [items addObject:[self makeGroup:@"OPERATING SYSTEM"]];

    NSString *version = [prefs stringForKey:@"SelectedVersion"] ?: @"Not selected";
    NSString *build = [prefs stringForKey:@"SelectedBuild"] ?: @"Not selected";

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"%@ • %@", version, build]]];

    [items addObject:
     [self makeSwitch:@"Show beta builds"
                  key:@"ShowBetaBuilds"
          defaultValue:NO]];

    [items addObject:
     [self makeButton:@"Choose iOS / iPadOS"
               action:@selector(openFirmwarePicker)]];

    [items addObject:[self makeGroup:@"WRITE"]];

    [items addObject:
     [self makeButton:@"Apply Config"
               action:@selector(applyConfig)]];

    [items addObject:
     [self makeButton:@"Apply iOS"
               action:@selector(applyIOS)]];

    [items addObject:
     [self makeButton:@"Apply All"
               action:@selector(applyAll)]];

    [items addObject:[self makeGroup:@"COMPATIBILITY"]];

    [items addObject:
     [self makeSwitch:@"Non-standard combinations"
                  key:@"NonStandardCombinations"
          defaultValue:NO]];

    [items addObject:[self makeGroup:@"APPLICATION SCOPE"]];

    [items addObject:
     [self makeSwitch:@"Global"
                  key:@"GlobalProfileEnabled"
          defaultValue:NO]];

    [items addObject:
     [self makeSwitch:@"Only in"
                  key:@"OnlyInEnabled"
          defaultValue:NO]];

    [items addObject:
     [self makeButton:@"Choose applications"
               action:@selector(openApplicationPicker)]];

    [items addObject:[self makeGroup:@"CATALOG STATUS"]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Devices (iPhone • iPad): %@",
       statistics[@"devices"] ?: @0]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"iOS builds • betas: %@ • %@",
       statistics[@"ios"] ?: @0,
       statistics[@"ios_beta"] ?: @0]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"iPadOS builds • betas: %@ • %@",
       statistics[@"ipados"] ?: @0,
       statistics[@"ipados_beta"] ?: @0]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Last update: %@",
       [self formattedUpdateDate]]]];

    [items addObject:
     [self makeButton:@"Refresh catalog"
               action:@selector(refreshCatalog)]];

    _specifiers = [items copy];
    return _specifiers;
}

#pragma mark - Save

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];

    [[self prefs] setObject:value forKey:key];

    if ([key isEqualToString:@"GlobalProfileEnabled"] && [value boolValue]) {
        [[self prefs] setBool:NO forKey:@"OnlyInEnabled"];
    }

    if ([key isEqualToString:@"OnlyInEnabled"] && [value boolValue]) {
        [[self prefs] setBool:NO forKey:@"GlobalProfileEnabled"];
    }

    [[self prefs] synchronize];

    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
