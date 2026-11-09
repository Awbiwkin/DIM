
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "DIMCatalogManager.h"

static NSString * const DIMDomain = @"com.dim.manager";

#pragma mark - Search Picker

@interface DIMPickerController : UITableViewController <UISearchBarDelegate>

@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, copy) NSString *pickerTitle;
@property (nonatomic, copy) NSString *displayKey;
@property (nonatomic, copy) NSString *valueKey;
@property (nonatomic, copy) void (^selectionHandler)(NSDictionary *item);

@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredItems;

@end

@implementation DIMPickerController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = self.pickerTitle;
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search";
    self.tableView.tableHeaderView = self.searchBar;

    self.filteredItems = self.items ?: @[];

    [self.tableView registerClass:[UITableViewCell class]
           forCellReuseIdentifier:@"DIMPickerCell"];
}

- (void)searchBar:(UISearchBar *)searchBar
textDidChange:(NSString *)searchText {

    if (searchText.length == 0) {
        self.filteredItems = self.items;
    } else {
        NSPredicate *predicate =
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,
                                              NSDictionary *bindings) {

            NSString *title = item[self.displayKey] ?: @"";
            NSString *value = item[self.valueKey] ?: @"";

            return [title localizedCaseInsensitiveContainsString:searchText] ||
                   [value localizedCaseInsensitiveContainsString:searchText];
        }];

        self.filteredItems =
        [self.items filteredArrayUsingPredicate:predicate];
    }

    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return self.filteredItems.count;
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

#pragma mark - DIM Device Controller

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

- (PSSpecifier *)makeButton:(NSString *)title
                     action:(SEL)action {

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

#pragma mark - Current Device

- (NSString *)currentDeviceName {
    NSString *identifier =
    [DIMCatalogManager currentDeviceIdentifier];

    NSDictionary *device =
    [[DIMCatalogManager sharedManager] deviceForIdentifier:identifier];

    if (device[@"name"]) {
        return device[@"name"];
    }

    if ([identifier isEqualToString:@"iPhone8,1"]) {
        return @"iPhone 6s";
    }

    return identifier.length > 0 ? identifier : @"Unknown Device";
}

- (NSString *)selectedDeviceName {
    NSString *identifier =
    [[self prefs] stringForKey:@"SelectedModel"];

    NSDictionary *device =
    [[DIMCatalogManager sharedManager] deviceForIdentifier:identifier];

    if (device[@"name"]) {
        return device[@"name"];
    }

    return identifier ?: @"Not selected";
}

- (NSString *)selectedFamily {
    NSString *family =
    [[self prefs] stringForKey:@"DeviceFamily"];

    if (!family) {
        family = [DIMCatalogManager currentDeviceFamily];
        [[self prefs] setObject:family forKey:@"DeviceFamily"];
    }

    return family;
}

- (NSString *)selectedModel {
    NSUserDefaults *prefs = [self prefs];

    NSString *model = [prefs stringForKey:@"SelectedModel"];

    if (!model.length) {
        model = [DIMCatalogManager currentDeviceIdentifier];

        if (model.length) {
            [prefs setObject:model forKey:@"SelectedModel"];
        }
    }

    return model ?: @"";
}

#pragma mark - Date

- (NSString *)formattedUpdateDate {
    NSDate *date =
    [[DIMCatalogManager sharedManager] lastUpdateDate];

    if (![date isKindOfClass:[NSDate class]]) {
        return @"Never";
    }

    NSDateFormatter *formatter =
    [[NSDateFormatter alloc] init];

    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;

    return [formatter stringFromDate:date];
}

#pragma mark - Picker

- (void)presentPickerWithTitle:(NSString *)title
                         items:(NSArray<NSDictionary *> *)items
                     displayKey:(NSString *)displayKey
                       valueKey:(NSString *)valueKey
                       selected:(void (^)(NSDictionary *item))selection {

    DIMPickerController *picker =
    [[DIMPickerController alloc] initWithStyle:UITableViewStyleInsetGrouped];

    picker.pickerTitle = title;
    picker.items = items;
    picker.displayKey = displayKey;
    picker.valueKey = valueKey;
    picker.selectionHandler = selection;

    [self.navigationController pushViewController:picker animated:YES];
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

        NSArray *devices =
        [[DIMCatalogManager sharedManager] devicesForFamily:family];

        NSString *currentIdentifier =
        [DIMCatalogManager currentDeviceIdentifier];

        BOOL currentExists = NO;

        for (NSDictionary *device in devices) {
            if ([device[@"identifier"] isEqualToString:currentIdentifier]) {
                currentExists = YES;
                break;
            }
        }

        if (currentExists) {
            [[self prefs] setObject:currentIdentifier
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
    NSString *family = [self selectedFamily];

    NSArray *devices =
    [[DIMCatalogManager sharedManager] devicesForFamily:family];

    NSMutableArray *items = [NSMutableArray array];

    for (NSDictionary *device in devices) {
        NSString *name = device[@"name"];
        NSString *identifier = device[@"identifier"];

        if (!name || !identifier) continue;

        NSString *display =
        [NSString stringWithFormat:@"%@ (%@)", name, identifier];

        [items addObject:@{
            @"name": display,
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

        [[self prefs] setObject:identifier
                         forKey:@"SelectedModel"];

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

    NSArray *firmwares =
    [[DIMCatalogManager sharedManager] firmwaresForDevice:identifier];

    NSMutableArray *items = [NSMutableArray array];

    for (NSDictionary *firmware in firmwares) {
        NSString *version = firmware[@"version"];
        NSString *build = firmware[@"build"];

        if (!version || !build) continue;

        NSString *display =
        [NSString stringWithFormat:@"%@ (%@)", version, build];

        [items addObject:@{
            @"name": display,
            @"value": version,
            @"build": build
        }];
    }

    __weak typeof(self) weakSelf = self;

    [self presentPickerWithTitle:@"Select iOS Build"
                           items:items
                       displayKey:@"name"
                         valueKey:@"value"
                         selected:^(NSDictionary *item) {

        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        [[self prefs] setObject:item[@"value"]
                         forKey:@"SelectedVersion"];

        [[self prefs] setObject:item[@"build"]
                         forKey:@"SelectedBuild"];

        [self reloadDIMInterface];
    }];
}

#pragma mark - Refresh

- (void)refreshCatalog {
    UIAlertController *loading =
    [UIAlertController alertControllerWithTitle:@"Updating Catalog"
                                        message:@"Loading device and OS databases..."
                                 preferredStyle:UIAlertControllerStyleAlert];

    [self presentViewController:loading animated:YES completion:nil];

    [[DIMCatalogManager sharedManager]
     refreshCatalogWithCompletion:^(BOOL success, NSString *message) {

        [loading dismissViewControllerAnimated:YES completion:^{

            [self reloadDIMInterface];

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

    DIMCatalogManager *catalog =
    [DIMCatalogManager sharedManager];

    NSUserDefaults *prefs = [self prefs];

    NSString *family = [self selectedFamily];
    NSString *model = [self selectedModel];

    NSString *deviceName = [self currentDeviceName];
    NSString *selectedName = [self selectedDeviceName];

    // CURRENT DEVICE

    [items addObject:[self makeGroup:@"CURRENT DEVICE"]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"%@ · %@",
       deviceName,
       [DIMCatalogManager currentDeviceIdentifier]]]];

    // SELECTED CONFIGURATION

    [items addObject:[self makeGroup:@"SELECTED CONFIGURATION"]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Family: %@", family]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Device: %@", selectedName]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"ProductType: %@", model]]];

    [items addObject:[self makeButton:@"Choose Device Family"
                               action:@selector(openFamilyPicker)]];

    [items addObject:[self makeButton:@"Choose Device Model"
                               action:@selector(openDevicePicker)]];

    // OPERATING SYSTEM

    [items addObject:[self makeGroup:@"OPERATING SYSTEM"]];

    NSString *version =
    [prefs stringForKey:@"SelectedVersion"] ?: @"Not selected";

    NSString *build =
    [prefs stringForKey:@"SelectedBuild"] ?: @"Not selected";

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"%@ · %@", version, build]]];

    NSArray *firmwares =
    [catalog firmwaresForDevice:model];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Available builds: %lu",
       (unsigned long)firmwares.count]]];

    [items addObject:
     [self makeButton:@"Choose iOS / iPadOS Build"
               action:@selector(openFirmwarePicker)]];

    if (firmwares.count == 0) {
        [items addObject:
         [self makeStatus:@"No firmware records in local cache."]];
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

    // CATALOG STATUS

    [items addObject:[self makeGroup:@"CATALOG STATUS"]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Devices: %lu",
       (unsigned long)[[prefs arrayForKey:@"DIMCatalogDevices"] count]]]];

    [items addObject:
     [self makeStatus:
      [NSString stringWithFormat:@"Last update: %@",
       [self formattedUpdateDate]]]];

    [items addObject:
     [self makeStatus:[catalog catalogStatus]]];

    // REFRESH AT THE BOTTOM

    [items addObject:[self makeGroup:@""]];

    [items addObject:
     [self makeButton:@"Refresh Catalog"
               action:@selector(refreshCatalog)]];

    _specifiers = [items copy];

    return _specifiers;
}

#pragma mark - Save Preferences

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    [[self prefs] synchronize];

    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
