
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <math.h>
#import <stdlib.h>

static NSString * const DIMDomain = @"com.dim.manager";
static NSString * const DIMSelectedAppsKey = @"SelectedApps";

@interface DIMAppProfilesController : UITableViewController <UISearchBarDelegate>

@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedApps;
@property (nonatomic, strong) UISearchBar *searchBar;

@end

@implementation DIMAppProfilesController

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];
}

- (UIImage *)decodeIconData:(NSData *)data {
    if (![data isKindOfClass:NSData.class] || data.length <= 32) {
        return nil;
    }

    // Первые 32 байта — служебный заголовок.
    NSUInteger pixelBytes = data.length - 32;

    if (pixelBytes % 4 != 0) {
        return nil;
    }

    NSUInteger pixelCount = pixelBytes / 4;
    NSUInteger dimension = (NSUInteger)sqrt((double)pixelCount);

    if (dimension == 0 || dimension * dimension != pixelCount) {
        return nil;
    }

    NSUInteger width = dimension;
    NSUInteger height = dimension;
    NSUInteger bytesPerRow = width * 4;

    void *pixels = calloc(height, bytesPerRow);

    if (!pixels) {
        return nil;
    }

    [data getBytes:pixels
             range:NSMakeRange(32, pixelBytes)];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    if (!colorSpace) {
        free(pixels);
        return nil;
    }

    CGContextRef context = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst
    );

    CGColorSpaceRelease(colorSpace);

    if (!context) {
        free(pixels);
        return nil;
    }

    CGImageRef cgImage = CGBitmapContextCreateImage(context);

    CGContextRelease(context);
    free(pixels);

    if (!cgImage) {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:cgImage
                                        scale:[UIScreen mainScreen].scale
                                  orientation:UIImageOrientationUp];

    CGImageRelease(cgImage);

    return image;
}

- (UIImage *)iconForApplication:(id)application {
    SEL selector = NSSelectorFromString(@"iconDataForVariant:");

    if (![application respondsToSelector:selector]) {
        return nil;
    }

    // Сначала основной вариант иконки.
    int variants[] = {2, 1, 0};

    for (NSUInteger i = 0; i < sizeof(variants) / sizeof(variants[0]); i++) {
        NSData *data = ((id (*)(id, SEL, int))objc_msgSend)(
            application,
            selector,
            variants[i]
        );

        UIImage *image = [self decodeIconData:data];

        if (image) {
            return image;
        }
    }

    return nil;
}

- (NSArray<NSDictionary *> *)installedApps {
    NSMutableArray *result = [NSMutableArray array];

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");

    if (!workspaceClass) return @[];

    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");

    if (![workspaceClass respondsToSelector:defaultSelector]) {
        return @[];
    }

    id workspace = ((id (*)(id, SEL))objc_msgSend)(
        workspaceClass,
        defaultSelector
    );

    if (!workspace) return @[];

    SEL appsSelector = NSSelectorFromString(@"allInstalledApplications");

    if (![workspace respondsToSelector:appsSelector]) {
        return @[];
    }

    id installed = ((id (*)(id, SEL))objc_msgSend)(
        workspace,
        appsSelector
    );

    if (![installed isKindOfClass:NSArray.class]) {
        return @[];
    }

    for (id app in installed) {
        SEL bundleSelector = NSSelectorFromString(@"bundleIdentifier");

        if (![app respondsToSelector:bundleSelector]) {
            bundleSelector = NSSelectorFromString(@"applicationIdentifier");
        }

        if (![app respondsToSelector:bundleSelector]) {
            continue;
        }

        id bundle = ((id (*)(id, SEL))objc_msgSend)(
            app,
            bundleSelector
        );

        if (![bundle isKindOfClass:NSString.class] ||
            ![(NSString *)bundle length]) {
            continue;
        }

        SEL nameSelector = NSSelectorFromString(@"localizedName");
        id name = nil;

        if ([app respondsToSelector:nameSelector]) {
            name = ((id (*)(id, SEL))objc_msgSend)(
                app,
                nameSelector
            );
        }

        if (![name isKindOfClass:NSString.class] ||
            ![(NSString *)name length]) {
            name = bundle;
        }

        UIImage *icon = [self iconForApplication:app];

        NSMutableDictionary *entry = [@{
            @"name": name,
            @"bundle": bundle
        } mutableCopy];

        if (icon) {
            entry[@"icon"] = icon;
        }

        [result addObject:entry];
    }

    [result sortUsingComparator:^NSComparisonResult(
        NSDictionary *a,
        NSDictionary *b
    ) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];

    return result;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Choose Applications";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 64.0;

    NSArray *saved = [[self prefs] arrayForKey:DIMSelectedAppsKey];

    self.selectedApps = [NSMutableSet set];

    if ([saved isKindOfClass:NSArray.class]) {
        for (id bundle in saved) {
            if ([bundle isKindOfClass:NSString.class]) {
                [self.selectedApps addObject:bundle];
            }
        }
    }

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search installed apps";
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [self.searchBar sizeToFit];

    self.tableView.tableHeaderView = self.searchBar;

    self.navigationItem.rightBarButtonItem =
    [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self
        action:@selector(finishSelection)];

    [self reloadApps];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)reloadApps {
    self.apps = [self installedApps];
    self.filteredApps = self.apps ?: @[];
    [self.tableView reloadData];
}

- (void)finishSelection {
    NSArray *selected = [[self.selectedApps allObjects]
        sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    [[self prefs] setObject:selected forKey:DIMSelectedAppsKey];
    [[self prefs] synchronize];

    [self.navigationController popViewControllerAnimated:YES];
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
            [app[@"name"] localizedCaseInsensitiveContainsString:searchText] ||
            [app[@"bundle"] localizedCaseInsensitiveContainsString:searchText];
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
        @"%lu selected · %lu applications",
        (unsigned long)self.selectedApps.count,
        (unsigned long)self.filteredApps.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    static NSString *identifier = @"DIMApplicationSelectionCell";

    UITableViewCell *cell =
    [tableView dequeueReusableCellWithIdentifier:identifier];

    if (!cell) {
        cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle
            reuseIdentifier:identifier];

        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.layer.cornerRadius = 10.0;
        cell.imageView.clipsToBounds = YES;
    }

    NSDictionary *app = self.filteredApps[indexPath.row];
    NSString *bundle = app[@"bundle"];

    cell.textLabel.text = app[@"name"];
    cell.detailTextLabel.text = bundle;

    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;

    cell.imageView.image = app[@"icon"];

    cell.accessoryType =
        [self.selectedApps containsObject:bundle]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;

    return cell;
}

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {

    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row >= self.filteredApps.count) return;

    NSString *bundle = self.filteredApps[indexPath.row][@"bundle"];

    if ([self.selectedApps containsObject:bundle]) {
        [self.selectedApps removeObject:bundle];
    } else {
        [self.selectedApps addObject:bundle];
    }

    [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                          withRowAnimation:UITableViewRowAnimationNone];
}

@end
