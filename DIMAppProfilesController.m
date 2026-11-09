
#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString * const DIMDomain = @"com.dim.manager";
static NSString * const DIMProfilesKey = @"AppProfiles";

@interface DIMAppProfilesController : UITableViewController <UISearchBarDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredApps;
@property (nonatomic, strong) UISearchBar *searchBar;
@end

@implementation DIMAppProfilesController

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];
}

- (NSDictionary *)savedProfiles {
    NSDictionary *profiles = [[self prefs] dictionaryForKey:DIMProfilesKey];
    return [profiles isKindOfClass:NSDictionary.class] ? profiles : @{};
}

- (NSString *)modeForBundle:(NSString *)bundleID {
    NSString *mode = [self savedProfiles][bundleID];
    return mode.length ? mode : @"Global";
}

- (NSArray<NSDictionary *> *)installedApps {
    NSMutableArray *result = [NSMutableArray array];

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return @[];

    id workspace =
        ((id (*)(id, SEL))objc_msgSend)(
            workspaceClass, NSSelectorFromString(@"defaultWorkspace")
        );

    if (!workspace) return @[];

    NSArray *installed =
        ((id (*)(id, SEL))objc_msgSend)(
            workspace, NSSelectorFromString(@"allInstalledApplications")
        );

    if (![installed isKindOfClass:NSArray.class]) return @[];

    for (id app in installed) {
        NSString *bundleID =
            ((id (*)(id, SEL))objc_msgSend)(
                app, NSSelectorFromString(@"bundleIdentifier")
            );

        if (![bundleID isKindOfClass:NSString.class] ||
            bundleID.length == 0) {
            continue;
        }

        NSString *name =
            ((id (*)(id, SEL))objc_msgSend)(
                app, NSSelectorFromString(@"localizedName")
            );

        if (![name isKindOfClass:NSString.class] || !name.length) {
            name = bundleID;
        }

        [result addObject:@{
            @"name": name,
            @"bundle": bundleID
        }];
    }

    [result sortUsingComparator:^NSComparisonResult(
        NSDictionary *a, NSDictionary *b
    ) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];

    return result;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"App Profiles";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
            target:self
            action:@selector(reloadApps)];

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search installed apps";
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;

    self.tableView.tableHeaderView = self.searchBar;

    [self.tableView registerClass:UITableViewCell.class
           forCellReuseIdentifier:@"DIMAppCell"];

    [self reloadApps];
}

- (void)reloadApps {
    self.apps = [self installedApps];
    self.filteredApps = self.apps;
    [self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar
    textDidChange:(NSString *)searchText {

    if (!searchText.length) {
        self.filteredApps = self.apps;
    } else {
        NSPredicate *predicate =
            [NSPredicate predicateWithBlock:^BOOL(
                NSDictionary *app, NSDictionary *bindings
            ) {
                return [app[@"name"]
                    localizedCaseInsensitiveContainsString:searchText] ||
                    [app[@"bundle"]
                    localizedCaseInsensitiveContainsString:searchText];
            }];

        self.filteredApps =
            [self.apps filteredArrayUsingPredicate:predicate];
    }

    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return self.filteredApps.count;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"%lu installed applications",
            (unsigned long)self.filteredApps.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"DIMAppCell"
                                        forIndexPath:indexPath];

    NSDictionary *app = self.filteredApps[indexPath.row];
    NSString *bundleID = app[@"bundle"];
    NSString *mode = [self modeForBundle:bundleID];

    cell.textLabel.text = app[@"name"];
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.text =
        [NSString stringWithFormat:@"%@ · %@", mode, bundleID];

    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    return cell;
}

- (void)saveMode:(NSString *)mode forBundle:(NSString *)bundleID {
    NSMutableDictionary *profiles =
        [[self savedProfiles] mutableCopy];

    if ([mode isEqualToString:@"Global"]) {
        [profiles removeObjectForKey:bundleID];
    } else {
        profiles[bundleID] = mode;
    }

    [[self prefs] setObject:profiles forKey:DIMProfilesKey];
    [[self prefs] synchronize];

    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {

    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *app = self.filteredApps[indexPath.row];
    NSString *bundleID = app[@"bundle"];
    NSString *name = app[@"name"];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:name
                                            message:bundleID
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;

    [alert addAction:
        [UIAlertAction actionWithTitle:@"Global Profile"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
            [weakSelf saveMode:@"Global" forBundle:bundleID];
        }]];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"Original Identity"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
            [weakSelf saveMode:@"Original" forBundle:bundleID];
        }]];

    [alert addAction:
        [UIAlertAction actionWithTitle:@"Cancel"
                                 style:UIAlertActionStyleCancel
                               handler:nil]];

    UITableViewCell *selectedCell =
        [tableView cellForRowAtIndexPath:indexPath];

    alert.popoverPresentationController.sourceView =
        selectedCell ?: self.view;

    alert.popoverPresentationController.sourceRect =
        selectedCell ? selectedCell.bounds : self.view.bounds;

    [self presentViewController:alert animated:YES completion:nil];
}

@end
