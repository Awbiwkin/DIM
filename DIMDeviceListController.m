
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "DIMCatalogManager.h"

static NSString * const DIMDomain = @"com.dim.manager";

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
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

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
            NSString *name = item[self.displayKey] ?: @"";
            NSString *value = item[self.valueKey] ?: @"";
            NSString *build = item[@"build"] ?: @"";

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
- (void)openFirmwarePicker;
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
    return board.length ? board : @"Not available";
}

- (NSString *)modelNumbers {
    id models = [self selectedDevice][@"models"];

    if ([models isKindOfClass:NSArray.class] && [models count] > 0) {
        return [models componentsJoinedByString:@", "];
    }

    return @"Not available";
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

        [[self prefs] removeObjectForKey:@"SelectedVersion"];
        [[self prefs] removeObjectForKey:@"SelectedBuild"];

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
            @"name": [NSString stringWithFormat:@"%@ (%@) · %@",
                      name, identifier, board],
            @"value": identifier
        }];
    }

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
        [[self prefs] removeObjectForKey:@"SelectedVersion"];
        [[self prefs] removeObjectForKey:@"SelectedBuild"];

        [self reloadDIMInterface];

        [[DIMCatalogManager sharedManager]
         refreshFirmwaresForDevice:identifier
         completion:^(BOOL success, NSString *message) {
            [self reloadDIMInterface];
        }];
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

        if ([firmware[@"is_beta"] boolValue]) {
            [labels addObject:@"BETA"];
        }

        if (![firmware[@"compatible"] boolValue]) {
            [labels addObject:@"NON-STANDARD"];
        }

        if ([firmware[@"signed"] respondsToSelector:@selector(boolValue)]) {
            [labels addObject:
             ([firmware[@"signed"] boolValue] ? @"SIGNED" : @"UNSIGNED")];
        }

        NSString *suffix = labels.count
        ? [NSString stringWithFormat:@" · %@",
           [labels componentsJoinedByString:@" · "]]
        : @"";

        NSMutableDictionary *entry = [firmware mutableCopy];

        entry[@"name"] =
        [NSString stringWithFormat:@"%@ (%@)%@", version, build, suffix];

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

        [self reloadDIMInterface];
    }];
}

#pragma mark - Refresh

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

    NSString *family = [self selectedFamily];
    NSString *model = [self selectedModel];

    NSDictionary *statistics = [catalog catalogStatistics];

    [items addObject:[self makeGroup:@"CURRENT DEVICE"]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"%@ · %@",
       [self currentDeviceName],
       [DIMCatalogManager currentDeviceIdentifier]]]];

    [items addObject:[self makeGroup:@"SELECTED CONFIGURATION"]];

    [items addObject:
     [self makeStatus:[NSString stringWithFormat:@"Family: %@", family]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Device: %@", [self selectedDeviceName]]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"ProductType: %@",
       model.length ? model : @"Not selected"]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"BoardConfig: %@",
       [self boardConfiguration]]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Model Number: %@",
       [self modelNumbers]]]];

    [items addObject:
     [self makeButton:@"Choose Device Family"
               action:@selector(openFamilyPicker)]];

    [items addObject:
     [self makeButton:@"Choose Device Model"
               action:@selector(openDevicePicker)]];

    [items addObject:[self makeGroup:@"OPERATING SYSTEM"]];

    NSString *version =
    [prefs stringForKey:@"SelectedVersion"] ?: @"Not selected";

    NSString *build =
    [prefs stringForKey:@"SelectedBuild"] ?: @"Not selected";

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"%@ · %@", version, build]]];

    NSArray *available =
    [catalog buildsForDevice:model
                includeBetas:YES
          allowIncompatible:YES];

    NSUInteger betaCount = 0;
    for (NSDictionary *entry in available) {
        if ([entry[@"is_beta"] boolValue]) betaCount++;
    }

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Available builds: %lu · Beta: %lu",
       (unsigned long)available.count,
       (unsigned long)betaCount]]];

    [items addObject:
     [self makeSwitch:@"Show Beta Builds"
                  key:@"ShowBetaBuilds"
          defaultValue:NO]];

    [items addObject:
     [self makeButton:@"Choose iOS / iPadOS Build"
               action:@selector(openFirmwarePicker)]];

    [items addObject:[self makeGroup:@"COMPATIBILITY"]];

    [items addObject:
     [self makeSwitch:@"Non-standard combinations"
                  key:@"NonStandardCombinations"
          defaultValue:NO]];

    [items addObject:[self makeGroup:@"CATALOG STATUS"]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Devices: %@",
       statistics[@"devices"] ?: @0]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"iOS builds: %@ · Betas: %@",
       statistics[@"ios"] ?: @0,
       statistics[@"ios_beta"] ?: @0]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"iPadOS builds: %@ · Betas: %@",
       statistics[@"ipados"] ?: @0,
       statistics[@"ipados_beta"] ?: @0]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Last update: %@",
       [self formattedUpdateDate]]]];

    [items addObject:[self makeStatus:[catalog catalogStatus]]];

    [items addObject:[self makeGroup:@""]];

    [items addObject:
     [self makeButton:@"Refresh Catalog"
               action:@selector(refreshCatalog)]];

    _specifiers = [items copy];
    return _specifiers;
}

#pragma mark - Save

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    [[self prefs] synchronize];

    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
