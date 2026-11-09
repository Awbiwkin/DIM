
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
    NSDictionary *profiles =
        [[self prefs] dictionaryForKey:DIMProfilesKey];

    return [profiles isKindOfClass:NSDictionary.class]
        ? profiles
        : @{};
}

- (NSString *)modeForBundle:(NSString *)bundleID {
    NSString *mode = [self savedProfiles][bundleID];
    return mode.length ? mode : @"Global";
}

- (NSArray<NSDictionary *> *)installedApps {
    NSMutableArray *result = [NSMutableArray array];

    Class workspaceClass =
        NSClassFromString(@"LSApplicationWorkspace");

    if (!workspaceClass) {
        return @[];
    }

    SEL defaultSelector =
        NSSelectorFromString(@"defaultWorkspace");

    if (![workspaceClass respondsToSelector:defaultSelector]) {
        return @[];
    }

    id workspace =
        ((id (*)(id, SEL))objc_msgSend)(
            workspaceClass,
            defaultSelector
        );

    if (!workspace) {
        return @[];
    }

    SEL appsSelector =
        NSSelectorFromString(@"allInstalledApplications");

    if (![workspace respondsToSelector:appsSelector]) {
        return @[];
    }

    id installed =
        ((id (*)(id, SEL))objc_msgSend)(
            workspace,
            appsSelector
        );

    if (![installed isKindOfClass:NSArray.class]) {
        return @[];
    }

    for (id app in installed) {
        SEL bundleSelector =
            NSSelectorFromString(@"bundleIdentifier");

        if (![app respondsToSelector:bundleSelector]) {
            continue;
        }

        id bundle =
            ((id (*)(id, SEL))objc_msgSend)(
                app,
                bundleSelector
            );

        if (![bundle isKindOfClass:NSString.class] ||
            ![bundle length]) {
            continue;
        }

        SEL nameSelector =
            NSSelectorFromString(@"localizedName");

        id name = nil;

        if ([app respondsToSelector:nameSelector]) {
            name =
                ((id (*)(id, SEL))objc_msgSend)(
                    app,
                    nameSelector
                );
        }

        if (![name isKindOfClass:NSString.class] ||
            ![name length]) {
            name = bundle;
        }

        [result addObject:@{
            @"name": name,
            @"bundle": bundle
        }];
    }

    [result sortUsingComparator:^NSComparisonResult(
        NSDictionary *a,
        NSDictionary *b
    ) {
        return [a[@"name"]
            localizedStandardCompare:b[@"name"]];
    }];

    return result;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"App Profiles";

    self.view.backgroundColor =
        UIColor.systemGroupedBackgroundColor;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
            target:self
            action:@selector(reloadApps)];

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search installed apps";
    self.searchBar.autocorrectionType =
        UITextAutocorrectionTypeNo;
    self.searchBar.autocapitalizationType =
        UITextAutocapitalizationTypeNone;

    [self.searchBar sizeToFit];

    self.tableView.tableHeaderView = self.searchBar;

    self.apps = @[];
    self.filteredApps = @[];

    [self reloadApps];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadApps];
}

- (void)reloadApps {
    self.apps = [self installedApps];
    self.filteredApps = self.apps ?: @[];

    [self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)searchBar
    textDidChange:(NSString *)searchText {

    if (!searchText.length) {
        self.filteredApps = self.apps;
    } else {
        NSPredicate *predicate =
            [NSPredicate predicateWithBlock:^BOOL(
                NSDictionary *app,
                NSDictionary *bindings
            ) {
                return
                    [app[@"name"]
                        localizedCaseInsensitiveContainsString:searchText]
                    ||
                    [app[@"bundle"]
                        localizedCaseInsensitiveContainsString:searchText];
            }];

        self.filteredApps =
            [self.apps filteredArrayUsingPredicate:predicate];
    }

    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {

    return self.filteredApps.count;
}

- (NSString *)tableView:(UITableView *)tableView
 titleForHeaderInSection:(NSInteger)section {

    return [NSString stringWithFormat:
        @"%lu installed applications",
        (unsigned long)self.filteredApps.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    static NSString *identifier = @"DIMAppCell";

    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
            reuseIdentifier:identifier];
    }

    NSDictionary *app = self.filteredApps[indexPath.row];

    NSString *bundleID = app[@"bundle"];
    NSString *mode = [self modeForBundle:bundleID];

    cell.textLabel.text = app[@"name"];

    cell.detailTextLabel.text =
        [NSString stringWithFormat:@"%@ · %@",
            mode,
            bundleID];

    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 1;

    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor =
        UIColor.secondaryLabelColor;

    cell.accessoryType =
        UITableViewCellAccessoryDisclosureIndicator;

    return cell;
}

- (void)saveMode:(NSString *)mode
       forBundle:(NSString *)bundleID {

    NSMutableDictionary *profiles =
        [[self savedProfiles] mutableCopy];

    if ([mode isEqualToString:@"Global"]) {
        [profiles removeObjectForKey:bundleID];
    } else {
        profiles[bundleID] = mode;
    }

    [[self prefs] setObject:profiles
                     forKey:DIMProfilesKey];

    [[self prefs] synchronize];

    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {

    [tableView deselectRowAtIndexPath:indexPath
                             animated:YES];

    if (indexPath.row >= self.filteredApps.count) {
        return;
    }

    NSDictionary *app = self.filteredApps[indexPath.row];

    NSString *bundleID = app[@"bundle"];
    NSString *name = app[@"name"];

    UIAlertController *alert =
        [UIAlertController
            alertControllerWithTitle:name
            message:bundleID
            preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;

    [alert addAction:
        [UIAlertAction
            actionWithTitle:@"Global Profile"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                [weakSelf saveMode:@"Global"
                         forBundle:bundleID];
            }]];

    [alert addAction:
        [UIAlertAction
            actionWithTitle:@"Original Identity"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                [weakSelf saveMode:@"Original"
                         forBundle:bundleID];
            }]];

    [alert addAction:
        [UIAlertAction
            actionWithTitle:@"Cancel"
            style:UIAlertActionStyleCancel
            handler:nil]];

    alert.popoverPresentationController.sourceView =
        self.tableView;

    alert.popoverPresentationController.sourceRect =
        [tableView rectForRowAtIndexPath:indexPath];

    [self presentViewController:alert
                       animated:YES
                     completion:nil];
}

@end
