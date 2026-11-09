
#import "DIMCatalogManager.h"

static NSString * const DIMCatalogDomain = @"com.dim.manager";

static NSString * const DIMIPSWDevicesURL =
@"https://ipsw.info/api/v1/devices?format=full";

static NSString * const DIMIPSWReleasesURL =
@"https://ipsw.info/api/v1/releases";

static NSString * const DIMAppleDBDevicesURL =
@"https://api.appledb.dev/device/index.json";

static NSString * const DIMAppleDBVersionsURL =
@"https://api.appledb.dev/ios/index.json";

@interface DIMCatalogManager ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation DIMCatalogManager

+ (instancetype)sharedManager {
    static DIMCatalogManager *manager;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        manager = [[DIMCatalogManager alloc] init];
    });

    return manager;
}

- (instancetype)init {
    self = [super init];

    if (self) {
        NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];

        configuration.timeoutIntervalForRequest = 35;
        configuration.timeoutIntervalForResource = 60;
        configuration.HTTPMaximumConnectionsPerHost = 4;

        _session =
        [NSURLSession sessionWithConfiguration:configuration];
    }

    return self;
}

- (NSUserDefaults *)preferences {
    return [[NSUserDefaults alloc] initWithSuiteName:DIMCatalogDomain];
}

- (NSArray<NSDictionary *> *)devicesForFamily:(NSString *)family {
    NSArray *devices =
    [[self preferences] arrayForKey:@"DIMCatalogDevices"];

    if (![devices isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSPredicate *predicate =
    [NSPredicate predicateWithBlock:^BOOL(NSDictionary *device, NSDictionary *bindings) {
        return [device[@"product_type"] isEqualToString:family];
    }];

    NSArray *filtered = [devices filteredArrayUsingPredicate:predicate];

    return [filtered sortedArrayUsingComparator:^NSComparisonResult(
        NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
}

- (NSArray<NSDictionary *> *)versionsForFamily:(NSString *)family {
    NSString *osFamily =
    [family isEqualToString:@"iPad"] ? @"iPadOS" : @"iOS";

    NSArray *versions =
    [[self preferences] arrayForKey:@"DIMCatalogVersions"];

    if (![versions isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSPredicate *predicate =
    [NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *bindings) {
        return [item[@"family"] isEqualToString:osFamily];
    }];

    NSArray *filtered = [versions filteredArrayUsingPredicate:predicate];

    return [filtered sortedArrayUsingComparator:^NSComparisonResult(
        NSDictionary *a, NSDictionary *b) {
        return [b[@"version"] compare:a[@"version"]
                              options:NSNumericSearch];
    }];
}

- (NSDate *)lastUpdateDate {
    return [[self preferences] objectForKey:@"DIMCatalogLastUpdated"];
}

- (NSString *)catalogStatus {
    return [[self preferences] stringForKey:@"DIMCatalogStatus"]
        ?: @"Catalog has not been updated yet.";
}

- (NSDictionary *)deviceDictionaryFromObject:(id)object {
    if (![object isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSDictionary *source = object;

    NSString *name = source[@"name"];
    NSString *identifier = source[@"identifier"];
    NSString *type = source[@"product_type"];

    if (![name isKindOfClass:[NSString class]] ||
        ![identifier isKindOfClass:[NSString class]] ||
        ![type isKindOfClass:[NSString class]]) {
        return nil;
    }

    if (![type isEqualToString:@"iPhone"] &&
        ![type isEqualToString:@"iPad"]) {
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    result[@"name"] = name;
    result[@"identifier"] = identifier;
    result[@"product_type"] = type;

    if ([source[@"boardconfig"] isKindOfClass:[NSString class]]) {
        result[@"boardconfig"] = source[@"boardconfig"];
    }

    if ([source[@"models"] isKindOfClass:[NSArray class]]) {
        result[@"models"] = source[@"models"];
    }

    if ([source[@"introduction"] isKindOfClass:[NSString class]]) {
        result[@"introduction"] = source[@"introduction"];
    }

    if ([source[@"launch_os_version"] isKindOfClass:[NSString class]]) {
        result[@"launch_os_version"] = source[@"launch_os_version"];
    }

    return result;
}

- (NSString *)versionFromOperatingSystemName:(NSString *)name {
    if (![name isKindOfClass:[NSString class]]) {
        return nil;
    }

    NSError *error = nil;

    NSRegularExpression *regex =
    [NSRegularExpression regularExpressionWithPattern:
     @"[0-9]+(?:\\.[0-9]+){0,3}"
                                              options:0
                                                error:&error];

    NSTextCheckingResult *match =
    [regex firstMatchInString:name
                      options:0
                        range:NSMakeRange(0, name.length)];

    if (!match) {
        return nil;
    }

    return [name substringWithRange:match.range];
}

- (void)addVersion:(NSString *)version
              build:(NSString *)build
             family:(NSString *)family
            toArray:(NSMutableArray *)array
             unique:(NSMutableSet *)unique {

    if (version.length == 0 || family.length == 0) {
        return;
    }

    NSString *safeBuild =
    [build isKindOfClass:[NSString class]] ? build : @"";

    NSString *key =
    [NSString stringWithFormat:@"%@|%@|%@", family, version, safeBuild];

    if ([unique containsObject:key]) {
        return;
    }

    [unique addObject:key];

    [array addObject:@{
        @"family": family,
        @"version": version,
        @"build": safeBuild
    }];
}

- (void)parseAppleDBVersionIndex:(id)json
                         toArray:(NSMutableArray *)versions
                          unique:(NSMutableSet *)unique {

    if (![json isKindOfClass:[NSArray class]]) {
        return;
    }

    for (id entry in (NSArray *)json) {
        if (![entry isKindOfClass:[NSString class]]) {
            continue;
        }

        NSArray *parts = [entry componentsSeparatedByString:@";"];

        if (parts.count < 2) {
            continue;
        }

        NSString *osName = parts[0];
        NSString *build = parts[1];

        NSString *family = nil;

        if ([osName localizedCaseInsensitiveContainsString:@"iPadOS"]) {
            family = @"iPadOS";
        } else if ([osName localizedCaseInsensitiveContainsString:@"iOS"]) {
            family = @"iOS";
        }

        if (!family) {
            continue;
        }

        NSString *version =
        [self versionFromOperatingSystemName:osName];

        if (!version) {
            continue;
        }

        [self addVersion:version
                   build:build
                  family:family
                 toArray:versions
                  unique:unique];
    }
}

- (void)parseIPSWReleases:(id)json
                  toArray:(NSMutableArray *)versions
                   unique:(NSMutableSet *)unique {

    if (![json isKindOfClass:[NSArray class]]) {
        return;
    }

    for (id entry in (NSArray *)json) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *name = entry[@"name"];

        if (![name isKindOfClass:[NSString class]]) {
            continue;
        }

        NSString *family = nil;

        if ([name localizedCaseInsensitiveContainsString:@"iPadOS"]) {
            family = @"iPadOS";
        } else if ([name localizedCaseInsensitiveContainsString:@"iOS"]) {
            family = @"iOS";
        }

        if (!family) {
            continue;
        }

        NSString *version =
        [self versionFromOperatingSystemName:name];

        if (!version) {
            continue;
        }

        [self addVersion:version
                   build:@""
                  family:family
                 toArray:versions
                  unique:unique];
    }
}

- (void)requestURL:(NSString *)url
        completion:(void (^)(id json, BOOL success))completion {

    NSURL *URL = [NSURL URLWithString:url];

    if (!URL) {
        completion(nil, NO);
        return;
    }

    NSMutableURLRequest *request =
    [NSMutableURLRequest requestWithURL:URL];

    request.HTTPMethod = @"GET";
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task =
    [self.session dataTaskWithRequest:request
                    completionHandler:^(NSData *data,
                                        NSURLResponse *response,
                                        NSError *error) {

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;

        if (error || !data || http.statusCode < 200 ||
            http.statusCode >= 300) {
            completion(nil, NO);
            return;
        }

        NSError *jsonError = nil;

        id json = [NSJSONSerialization JSONObjectWithData:data
                                                  options:NSJSONReadingFragmentsAllowed
                                                    error:&jsonError];

        if (jsonError || !json) {
            completion(nil, NO);
            return;
        }

        completion(json, YES);
    }];

    [task resume];
}

- (void)refreshCatalogWithCompletion:
(void (^)(BOOL success, NSString *message))completion {

    dispatch_group_t group = dispatch_group_create();

    __block id ipswDevices = nil;
    __block id ipswReleases = nil;
    __block id appleDevices = nil;
    __block id appleVersions = nil;

    __block BOOL ipswDevicesOK = NO;
    __block BOOL ipswReleasesOK = NO;
    __block BOOL appleDevicesOK = NO;
    __block BOOL appleVersionsOK = NO;

    NSArray *urls = @[
        DIMIPSWDevicesURL,
        DIMIPSWReleasesURL,
        DIMAppleDBDevicesURL,
        DIMAppleDBVersionsURL
    ];

    for (NSUInteger index = 0; index < urls.count; index++) {
        dispatch_group_enter(group);

        [self requestURL:urls[index]
              completion:^(id json, BOOL success) {

            switch (index) {
                case 0:
                    ipswDevices = json;
                    ipswDevicesOK = success;
                    break;

                case 1:
                    ipswReleases = json;
                    ipswReleasesOK = success;
                    break;

                case 2:
                    appleDevices = json;
                    appleDevicesOK = success;
                    break;

                case 3:
                    appleVersions = json;
                    appleVersionsOK = success;
                    break;
            }

            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{

        NSUserDefaults *prefs = [self preferences];

        BOOL hasUsefulData = NO;

        NSMutableArray *devices = [NSMutableArray array];
        NSMutableArray *versions = [NSMutableArray array];
        NSMutableSet *versionKeys = [NSMutableSet set];

        if (ipswDevicesOK && [ipswDevices isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)ipswDevices) {
                NSDictionary *device = [self deviceDictionaryFromObject:item];

                if (device) {
                    [devices addObject:device];
                }
            }

            if (devices.count > 0) {
                [prefs setObject:devices forKey:@"DIMCatalogDevices"];
                hasUsefulData = YES;
            }
        }

        if (appleVersionsOK) {
            [self parseAppleDBVersionIndex:appleVersions
                                   toArray:versions
                                    unique:versionKeys];

            if (versions.count > 0) {
                hasUsefulData = YES;
            }
        }

        if (ipswReleasesOK) {
            [self parseIPSWReleases:ipswReleases
                            toArray:versions
                             unique:versionKeys];

            if (versions.count > 0) {
                hasUsefulData = YES;
            }
        }

        if (versions.count > 0) {
            [prefs setObject:versions forKey:@"DIMCatalogVersions"];
        }

        if (appleDevicesOK && [appleDevices isKindOfClass:[NSArray class]]) {
            [prefs setObject:appleDevices
                      forKey:@"DIMAppleDBDeviceIndex"];
            hasUsefulData = YES;
        }

        [prefs setObject:@{
            @"IPSWDevices": @(ipswDevicesOK),
            @"IPSWReleases": @(ipswReleasesOK),
            @"AppleDBDevices": @(appleDevicesOK),
            @"AppleDBVersions": @(appleVersionsOK)
        } forKey:@"DIMCatalogSourceStatus"];

        if (hasUsefulData) {
            [prefs setObject:[NSDate date]
                      forKey:@"DIMCatalogLastUpdated"];

            NSString *message =
            [NSString stringWithFormat:
             @"Updated: %lu devices, %lu OS builds.",
             (unsigned long)[[prefs arrayForKey:@"DIMCatalogDevices"] count],
             (unsigned long)[[prefs arrayForKey:@"DIMCatalogVersions"] count]];

            [prefs setObject:message forKey:@"DIMCatalogStatus"];
            [prefs synchronize];

            if (completion) {
                completion(YES, message);
            }

        } else {
            NSString *message =
            @"Update failed. Previous cached catalog was preserved.";

            [prefs setObject:message forKey:@"DIMCatalogStatus"];
            [prefs synchronize];

            if (completion) {
                completion(NO, message);
            }
        }
    });
}

@end
