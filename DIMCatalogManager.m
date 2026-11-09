
#import "DIMCatalogManager.h"
#import <sys/types.h>
#import <sys/sysctl.h>

static NSString * const DIMDomain = @"com.dim.manager";

static NSString * const DIMIPSWBase =
@"https://ipsw.info/api/v1";

static NSString * const DIMAppleDBBase =
@"https://api.appledb.dev";

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
        [NSURLSessionConfiguration defaultSessionConfiguration];

        configuration.timeoutIntervalForRequest = 30;
        configuration.timeoutIntervalForResource = 60;
        configuration.HTTPMaximumConnectionsPerHost = 4;

        _session =
        [NSURLSession sessionWithConfiguration:configuration];
    }

    return self;
}

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:DIMDomain];
}

#pragma mark - Device Detection

+ (NSString *)currentDeviceIdentifier {
    size_t size = 0;

    sysctlbyname("hw.machine", NULL, &size, NULL, 0);

    if (size == 0) {
        return @"";
    }

    char *machine = malloc(size);

    if (!machine) {
        return @"";
    }

    NSString *identifier = @"";

    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
        identifier =
        [NSString stringWithUTF8String:machine] ?: @"";
    }

    free(machine);

    return identifier;
}

+ (NSString *)currentDeviceFamily {
    NSString *identifier = [self currentDeviceIdentifier];

    if ([identifier hasPrefix:@"iPad"]) {
        return @"iPad";
    }

    return @"iPhone";
}

#pragma mark - HTTP

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
    request.timeoutInterval = 30;

    [request setValue:@"application/json"
   forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task =
    [self.session dataTaskWithRequest:request
                    completionHandler:^(NSData *data,
                                        NSURLResponse *response,
                                        NSError *error) {

        NSHTTPURLResponse *http =
        (NSHTTPURLResponse *)response;

        if (error || !data ||
            http.statusCode < 200 ||
            http.statusCode >= 300) {

            completion(nil, NO);
            return;
        }

        NSError *jsonError = nil;

        id json =
        [NSJSONSerialization JSONObjectWithData:data
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

#pragma mark - Device Catalog

- (NSArray<NSDictionary *> *)devicesForFamily:(NSString *)family {
    NSArray *devices =
    [[self prefs] arrayForKey:@"DIMCatalogDevices"];

    if (![devices isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray *result = [NSMutableArray array];

    for (NSDictionary *device in devices) {
        if (![device isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        if ([device[@"product_type"] isEqualToString:family]) {
            [result addObject:device];
        }
    }

    return [result sortedArrayUsingComparator:
    ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
}

- (NSDictionary *)deviceForIdentifier:(NSString *)identifier {
    if (identifier.length == 0) {
        return nil;
    }

    NSArray *devices =
    [[self prefs] arrayForKey:@"DIMCatalogDevices"];

    for (NSDictionary *device in devices) {
        if ([device[@"identifier"] isEqualToString:identifier]) {
            return device;
        }
    }

    return nil;
}

#pragma mark - Firmware Catalog

- (NSString *)firmwareCacheKey:(NSString *)identifier {
    NSString *safe =
    [identifier stringByReplacingOccurrencesOfString:@","
                                           withString:@"_"];

    return [@"DIMFirmware_" stringByAppendingString:safe];
}

- (NSArray<NSDictionary *> *)firmwaresForDevice:(NSString *)identifier {
    if (identifier.length == 0) {
        return @[];
    }

    NSArray *firmwares =
    [[self prefs] arrayForKey:[self firmwareCacheKey:identifier]];

    return [firmwares isKindOfClass:[NSArray class]] ? firmwares : @[];
}

- (void)refreshFirmwaresForDevice:(NSString *)identifier
                       completion:(void (^)(BOOL success, NSString *message))completion {

    if (identifier.length == 0) {
        if (completion) {
            completion(NO, @"Invalid device identifier.");
        }
        return;
    }

    NSString *escaped =
    [identifier stringByAddingPercentEncodingWithAllowedCharacters:
     [NSCharacterSet URLPathAllowedCharacterSet]];

    NSString *url =
    [NSString stringWithFormat:@"%@/device/%@", DIMIPSWBase, escaped];

    [self requestURL:url completion:^(id json, BOOL success) {

        if (!success || ![json isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(NO, @"Could not load firmware data. Existing cache was preserved.");
                }
            });
            return;
        }

        NSArray *source = json[@"firmwares"];

        if (![source isKindOfClass:[NSArray class]]) {
            source = @[];
        }

        NSMutableArray *result = [NSMutableArray array];

        for (NSDictionary *firmware in source) {
            if (![firmware isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            NSString *version = firmware[@"version"];
            NSString *build = firmware[@"buildid"];

            if (![version isKindOfClass:[NSString class]] ||
                ![build isKindOfClass:[NSString class]]) {
                continue;
            }

            NSMutableDictionary *entry =
            [NSMutableDictionary dictionary];

            entry[@"version"] = version;
            entry[@"build"] = build;

            if ([firmware[@"signed"] respondsToSelector:@selector(boolValue)]) {
                entry[@"signed"] = firmware[@"signed"];
            }

            if ([firmware[@"releasedate"] isKindOfClass:[NSString class]]) {
                entry[@"release_date"] = firmware[@"releasedate"];
            }

            if ([firmware[@"url"] isKindOfClass:[NSString class]]) {
                entry[@"url"] = firmware[@"url"];
            }

            [result addObject:entry];
        }

        [result sortUsingComparator:
         ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {

            NSString *versionA = a[@"version"] ?: @"";
            NSString *versionB = b[@"version"] ?: @"";

            NSComparisonResult comparison =
            [versionB compare:versionA options:NSNumericSearch];

            if (comparison == NSOrderedSame) {
                return [b[@"build"] compare:a[@"build"]
                                    options:NSNumericSearch];
            }

            return comparison;
        }];

        NSUserDefaults *prefs = [self prefs];

        [prefs setObject:result
                  forKey:[self firmwareCacheKey:identifier]];

        [prefs synchronize];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(YES,
                    [NSString stringWithFormat:
                     @"Loaded %lu firmware builds for %@.",
                     (unsigned long)result.count,
                     identifier]);
            }
        });
    }];
}

#pragma mark - AppleDB Version Index

- (NSArray<NSDictionary *> *)versionsForFamily:(NSString *)family {
    NSString *osType =
    [family isEqualToString:@"iPad"] ? @"iPadOS" : @"iOS";

    NSString *key =
    [osType isEqualToString:@"iPadOS"]
    ? @"DIMAppleDB_iPadOS"
    : @"DIMAppleDB_iOS";

    NSArray *versions = [[self prefs] arrayForKey:key];

    return [versions isKindOfClass:[NSArray class]] ? versions : @[];
}

- (NSArray *)parseAppleDBIndex:(id)json osType:(NSString *)osType {
    if (![json isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableDictionary *unique = [NSMutableDictionary dictionary];

    for (id item in (NSArray *)json) {
        if (![item isKindOfClass:[NSString class]]) {
            continue;
        }

        NSArray *parts = [item componentsSeparatedByString:@";"];

        if (parts.count < 2) {
            continue;
        }

        NSString *name = parts[0];
        NSString *build = parts[1];

        NSString *prefix =
        [osType stringByAppendingString:@" "];

        if (![name hasPrefix:prefix]) {
            continue;
        }

        NSString *version =
        [name substringFromIndex:prefix.length];

        if (version.length == 0 || build.length == 0) {
            continue;
        }

        NSString *key =
        [NSString stringWithFormat:@"%@|%@", version, build];

        unique[key] = @{
            @"version": version,
            @"build": build
        };
    }

    NSArray *result = [unique allValues];

    return [result sortedArrayUsingComparator:
    ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"version"] compare:a[@"version"]
                              options:NSNumericSearch];
    }];
}

#pragma mark - Full Catalog Refresh

- (void)refreshCatalogWithCompletion:
(void (^)(BOOL success, NSString *message))completion {

    dispatch_group_t group = dispatch_group_create();

    __block id iPhoneDevices = nil;
    __block id iPadDevices = nil;
    __block id iOSIndex = nil;
    __block id iPadOSIndex = nil;

    __block BOOL iPhoneOK = NO;
    __block BOOL iPadOK = NO;
    __block BOOL iOSOK = NO;
    __block BOOL iPadOSOK = NO;

    NSArray *urls = @[
        [NSString stringWithFormat:
         @"%@/devices?type=iPhone&format=full", DIMIPSWBase],

        [NSString stringWithFormat:
         @"%@/devices?type=iPad&format=full", DIMIPSWBase],

        [NSString stringWithFormat:
         @"%@/ios/iOS/index.json", DIMAppleDBBase],

        [NSString stringWithFormat:
         @"%@/ios/iPadOS/index.json", DIMAppleDBBase]
    ];

    for (NSUInteger i = 0; i < urls.count; i++) {
        dispatch_group_enter(group);

        [self requestURL:urls[i]
              completion:^(id json, BOOL success) {

            switch (i) {
                case 0:
                    iPhoneDevices = json;
                    iPhoneOK = success;
                    break;

                case 1:
                    iPadDevices = json;
                    iPadOK = success;
                    break;

                case 2:
                    iOSIndex = json;
                    iOSOK = success;
                    break;

                case 3:
                    iPadOSIndex = json;
                    iPadOSOK = success;
                    break;
            }

            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{

        NSUserDefaults *prefs = [self prefs];

        NSMutableArray *devices = [NSMutableArray array];

        NSArray *deviceSources = @[
            iPhoneDevices ?: [NSNull null],
            iPadDevices ?: [NSNull null]
        ];

        for (id source in deviceSources) {
            if (![source isKindOfClass:[NSArray class]]) {
                continue;
            }

            for (NSDictionary *item in (NSArray *)source) {
                if (![item isKindOfClass:[NSDictionary class]]) {
                    continue;
                }

                NSString *name = item[@"name"];
                NSString *identifier = item[@"identifier"];
                NSString *type = item[@"product_type"];

                if (![name isKindOfClass:[NSString class]] ||
                    ![identifier isKindOfClass:[NSString class]] ||
                    ![type isKindOfClass:[NSString class]]) {
                    continue;
                }

                if (![type isEqualToString:@"iPhone"] &&
                    ![type isEqualToString:@"iPad"]) {
                    continue;
                }

                NSMutableDictionary *device =
                [NSMutableDictionary dictionary];

                device[@"name"] = name;
                device[@"identifier"] = identifier;
                device[@"product_type"] = type;

                NSArray *copyKeys = @[
                    @"boardconfig",
                    @"models",
                    @"introduction",
                    @"launch_os_version",
                    @"apple_cpu",
                    @"screen",
                    @"cellular"
                ];

                for (NSString *key in copyKeys) {
                    id value = item[key];

                    if (value && value != [NSNull null]) {
                        device[key] = value;
                    }
                }

                [devices addObject:device];
            }
        }

        if (devices.count > 0) {
            [prefs setObject:devices
                      forKey:@"DIMCatalogDevices"];
        }

        NSArray *iosVersions =
        iOSOK ? [self parseAppleDBIndex:iOSIndex osType:@"iOS"] : nil;

        NSArray *ipadosVersions =
        iPadOSOK ? [self parseAppleDBIndex:iPadOSIndex osType:@"iPadOS"] : nil;

        if (iosVersions.count > 0) {
            [prefs setObject:iosVersions forKey:@"DIMAppleDB_iOS"];
        }

        if (ipadosVersions.count > 0) {
            [prefs setObject:ipadosVersions forKey:@"DIMAppleDB_iPadOS"];
        }

        NSDictionary *sourceStatus = @{
            @"IPSW_iPhone": @(iPhoneOK),
            @"IPSW_iPad": @(iPadOK),
            @"AppleDB_iOS": @(iOSOK),
            @"AppleDB_iPadOS": @(iPadOSOK)
        };

        [prefs setObject:sourceStatus forKey:@"DIMCatalogSourceStatus"];

        BOOL hasData =
        devices.count > 0 ||
        iosVersions.count > 0 ||
        ipadosVersions.count > 0;

        if (hasData) {
            [prefs setObject:[NSDate date]
                      forKey:@"DIMCatalogLastUpdated"];

            NSString *message =
            [NSString stringWithFormat:
             @"Devices: %lu. iOS builds: %lu. iPadOS builds: %lu.",
             (unsigned long)[[prefs arrayForKey:@"DIMCatalogDevices"] count],
             (unsigned long)[[prefs arrayForKey:@"DIMAppleDB_iOS"] count],
             (unsigned long)[[prefs arrayForKey:@"DIMAppleDB_iPadOS"] count]];

            [prefs setObject:message forKey:@"DIMCatalogStatus"];
            [prefs synchronize];

            if (completion) {
                completion(YES, message);
            }

        } else {
            NSString *message =
            @"All catalog sources failed. Previous cache was preserved.";

            [prefs setObject:message forKey:@"DIMCatalogStatus"];
            [prefs synchronize];

            if (completion) {
                completion(NO, message);
            }
        }
    });
}

#pragma mark - Status

- (NSDate *)lastUpdateDate {
    return [[self prefs] objectForKey:@"DIMCatalogLastUpdated"];
}

- (NSString *)catalogStatus {
    return [[self prefs] stringForKey:@"DIMCatalogStatus"]
    ?: @"Catalog has not been updated yet.";
}

@end
