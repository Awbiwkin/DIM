
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "DIMCatalogManager.h"
#import "DIMRuntime.h"

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
- (void)openDarwinPicker;
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
    DIMWriteRuntime([self prefs]);
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

// Регионы продаж Apple (суффикс номера модели, RegionInfo). Каталоги (AppleDB / IPSW)
// регионы не отдают, поэтому "Choose Region" раньше всегда показывал "Regions Unavailable".
// Список намеренно короткий и только из проверенных кодов, ничего не угадывается.
- (NSArray<NSDictionary *> *)builtinRegions {
    return @[
        @{@"name": @"LL/A — United States", @"value": @"LL/A"},
        @{@"name": @"C/A — Canada", @"value": @"C/A"},
        @{@"name": @"B/A — United Kingdom", @"value": @"B/A"},
        @{@"name": @"D/A — Germany", @"value": @"D/A"},
        @{@"name": @"FD/A — France", @"value": @"FD/A"},
        @{@"name": @"J/A — Japan", @"value": @"J/A"},
        @{@"name": @"KH/A — South Korea", @"value": @"KH/A"},
        @{@"name": @"X/A — Australia", @"value": @"X/A"},
        @{@"name": @"ZA/A — Singapore", @"value": @"ZA/A"},
        @{@"name": @"ZP/A — Hong Kong", @"value": @"ZP/A"},
        @{@"name": @"CH/A — China", @"value": @"CH/A"}
    ];
}

- (NSArray<NSString *> *)modelNumbersForSelectedRegion {
    NSString *selectedRegion = [self selectedRegion];
    BOOL catalogHasRegions = [self availableRegions].count > 0;
    NSMutableSet *numbers = [NSMutableSet set];

    for (NSDictionary *variant in [self modelVariants]) {
        NSString *region = variant[@"region"];
        NSString *modelNumber = variant[@"model"];

        if (!modelNumber.length) continue;

        // Фильтр по региону только если каталог действительно знает регионы.
        if (catalogHasRegions && selectedRegion.length &&
            ![region isEqualToString:selectedRegion]) {
            continue;
        }

        [numbers addObject:modelNumber];
    }

    // Каталог без регионов: показываем все номера моделей устройства.
    id models = [self selectedDevice][@"models"];

    if (!catalogHasRegions && [models isKindOfClass:NSArray.class]) {
        for (id number in (NSArray *)models) {
            if ([number isKindOfClass:NSString.class] && [number length]) {
                [numbers addObject:number];
            }
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

    if (major < 12 || major > 60 || minor < 0) return nil;

    // iOS 12...18: Darwin = iOS + 6 (iOS 18.x = Darwin 24.x, iOS 17.x = 23.x).
    // iOS 26+ (новая нумерация по годам): Darwin = iOS - 1 (iOS 26.x = Darwin 25.x).
    // Раньше всегда было +6, поэтому для iOS 26/27 получались 32.x / 33.x.
    NSInteger darwinMajor = (major >= 26) ? (major - 1) : (major + 6);

    return [NSString stringWithFormat:@"%ld.%ld.0",
            (long)darwinMajor, (long)minor];
}

- (BOOL)isDarwinString:(NSString *)value {
    if (![value isKindOfClass:NSString.class]) return NO;

    NSArray *parts = [value componentsSeparatedByString:@"."];
    if (parts.count != 3) return NO;

    for (NSString *part in parts) {
        if (!part.length) return NO;

        NSRange bad =
        [part rangeOfCharacterFromSet:
         NSCharacterSet.decimalDigitCharacterSet.invertedSet];

        if (bad.location != NSNotFound) return NO;
    }

    return YES;
}

// Приоритет: ручное значение -> Darwin из каталога -> расчёт по версии iOS.
- (NSString *)effectiveDarwinForVersion:(NSString *)version {
    NSString *manual = [[self prefs] stringForKey:@"DarwinOverride"];
    if ([self isDarwinString:manual]) return manual;

    NSString *catalog = [[self prefs] stringForKey:@"SelectedDarwinCatalog"];
    if ([self isDarwinString:catalog]) return catalog;

    return [self darwinVersionForIOS:version];
}

- (NSString *)darwinSourceLabel {
    if ([self isDarwinString:[[self prefs] stringForKey:@"DarwinOverride"]]) {
        return @"manual";
    }

    if ([self isDarwinString:[[self prefs] stringForKey:@"SelectedDarwinCatalog"]]) {
        return @"catalog";
    }

    return @"auto";
}

- (void)openDarwinPicker {
    UIAlertController *alert =
    [UIAlertController
        alertControllerWithTitle:@"Darwin Version"
                         message:@"Auto picks the Darwin version that matches the selected iOS. Enter a custom value (for example 24.3.0) only if you need to override it."
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"24.3.0";
        field.text = [[self prefs] stringForKey:@"DarwinOverride"];
        field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];

    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;

    [alert addAction:
     [UIAlertAction actionWithTitle:@"Use Auto"
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        [[self prefs] removeObjectForKey:@"DarwinOverride"];
        [[self prefs] synchronize];
        [self reloadDIMInterface];
    }]];

    [alert addAction:
     [UIAlertAction actionWithTitle:@"Set"
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        NSString *text =
        [weakAlert.textFields.firstObject.text
         stringByTrimmingCharactersInSet:
         NSCharacterSet.whitespaceAndNewlineCharacterSet];

        if (![self isDarwinString:text]) {
            [self showMessage:@"Use the format 24.3.0 (three numbers separated by dots)."
                        title:@"Invalid Darwin Version"];
            return;
        }

        [[self prefs] setObject:text forKey:@"DarwinOverride"];
        [[self prefs] synchronize];
        [self reloadDIMInterface];
    }]];

    [alert addAction:
     [UIAlertAction actionWithTitle:@"Cancel"
                              style:UIAlertActionStyleCancel
                            handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
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

    // Твик читает не NSUserDefaults, а маленький runtime plist.
    DIMWriteRuntime(prefs);
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
    NSString *darwin = [self effectiveDarwinForVersion:version];

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
    NSString *darwin = [self effectiveDarwinForVersion:version];

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
     [NSString stringWithFormat:@"%@ · %@\niOS: %@ · %@\n\nRestart the target app, then press Check.",
      profile[@"name"], profile[@"identifier"], version, build]
                title:@"Profile Applied"];
}

// Что сообщило целевое приложение (см. DIMPublishBeacon в Tweak.xm).
- (NSString *)beaconStatusForName:(NSString *)name expected:(uint64_t)expected {
    int token = 0;
    uint64_t state = 0;

    if (notify_register_check(name.UTF8String, &token) != NOTIFY_STATUS_OK) {
        return @"UNAVAILABLE";
    }

    notify_get_state(token, &state);
    notify_cancel(token);

    if (state == 0) return @"NOT RUN (open the app, keep it in background, press Check)";

    return state == expected ? @"SPOOFED" : @"MISMATCH (restart the app)";
}

- (void)checkActiveProfile {
    NSUserDefaults *prefs = [self prefs];

    // Обновляем runtime plist, чтобы Check работал с актуальными настройками.
    DIMWriteRuntime(prefs);

    NSDictionary *profile = [self activeProfile];

    BOOL configOK = [self profileHasConfig:profile];
    BOOL iosOK = [self profileHasIOS:profile];
    BOOL allOK = configOK && iosOK;

    BOOL anySpoofed = NO;
    BOOL anyBad = NO;

    NSMutableString *report = [NSMutableString string];

    [report appendFormat:@"Profile: config %@, iOS %@\n",
     configOK ? @"OK" : @"NO", iosOK ? @"OK" : @"NO"];

    BOOL enabled = [prefs objectForKey:@"Enabled"]
        ? [prefs boolForKey:@"Enabled"] : YES;

    BOOL global = [prefs boolForKey:@"GlobalProfileEnabled"];
    BOOL onlyIn = [prefs boolForKey:@"OnlyInEnabled"];

    if (!enabled || ![prefs boolForKey:@"DeviceEnabled"]) {
        [report appendString:@"DIM or Device Identity is switched off.\n"];
        anyBad = YES;
    } else if (!global && !onlyIn) {
        [report appendString:@"Application scope: enable Global or Only in.\n"];
        anyBad = YES;
    }

    if (allOK && (global || onlyIn)) {
        // Должно совпадать со строкой в DIMPublishBeacon (Tweak.xm):
        // hw.machine | kern.osversion | kern.osrelease | uname.machine | systemVersion
        NSString *signature =
        [NSString stringWithFormat:@"%@|%@|%@|%@|%@",
         profile[@"identifier"], profile[@"build"], profile[@"darwin"],
         profile[@"identifier"], profile[@"version"]];

        uint64_t expected = DIMFNV1a(signature.UTF8String);

        NSMutableArray<NSString *> *bundles = [NSMutableArray array];

        if (onlyIn) {
            for (id bundle in [prefs arrayForKey:@"SelectedApps"] ?: @[]) {
                if ([bundle isKindOfClass:NSString.class]) {
                    [bundles addObject:bundle];
                }
            }
        }

        [report appendString:@"\nIn target apps:\n"];

        for (NSString *bundle in bundles) {
            NSString *name = [@"com.dim.verify." stringByAppendingString:bundle];
            NSString *status = [self beaconStatusForName:name expected:expected];

            if ([status isEqualToString:@"SPOOFED"]) anySpoofed = YES;
            if ([status hasPrefix:@"MISMATCH"]) anyBad = YES;

            [report appendFormat:@"%@: %@\n", bundle, status];
        }

        if (global) {
            NSString *status =
            [self beaconStatusForName:@"com.dim.verify.last" expected:expected];

            if ([status isEqualToString:@"SPOOFED"]) anySpoofed = YES;
            if ([status hasPrefix:@"MISMATCH"]) anyBad = YES;

            [report appendFormat:@"Last app: %@\n", status];
        }
    } else if (!allOK) {
        [report appendString:@"\nPress Apply All first."];
        anyBad = YES;
    }

    [self reloadDIMInterface];

    NSString *title = anyBad ? @"Check: NOT OK"
                    : (anySpoofed ? @"Check: OK" : @"Check: NOT VERIFIED");

    [self showMessage:report title:title];
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

    NSMutableArray *items = [NSMutableArray array];

    if (regions.count > 0) {
        for (NSString *region in regions) {
            [items addObject:@{@"name": region, @"value": region}];
        }
    } else {
        // Каталог регионов не знает — используем встроенный список кодов Apple.
        [items addObjectsFromArray:[self builtinRegions]];
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

        NSString *catalogDarwin =
        [item[@"darwin"] isKindOfClass:NSString.class] ? item[@"darwin"] : nil;

        if ([self isDarwinString:catalogDarwin]) {
            [[self prefs] setObject:catalogDarwin forKey:@"SelectedDarwinCatalog"];
        } else {
            [[self prefs] removeObjectForKey:@"SelectedDarwinCatalog"];
        }

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
        ? @"Profile: complete (press Check to verify in apps)"
        : @"Profile: incomplete (press Apply All)";

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

    NSString *versionForDarwin = [prefs stringForKey:@"SelectedVersion"];
    NSString *darwinNow =
    versionForDarwin.length
        ? ([self effectiveDarwinForVersion:versionForDarwin] ?: @"unknown")
        : @"—";

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Darwin: %@ (%@)",
       darwinNow, [self darwinSourceLabel]]]];

    [items addObject:
     [self makeButton:@"Darwin version"
               action:@selector(openDarwinPicker)]];

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
    DIMWriteRuntime([self prefs]);

    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
