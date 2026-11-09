
#import "DIMCatalogManager.h"
#import <sys/types.h>
#import <sys/sysctl.h>
#import <UIKit/UIKit.h>

static NSString * const DIMDomain = @"com.dim.manager";
static NSString * const DIMIPSWBase = @"https://ipsw.info/api/v1";
static NSString * const DIMAppleDBBase = @"https://api.appledb.dev";

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

        configuration.timeoutIntervalForRequest = 45;
        configuration.timeoutIntervalForResource = 120;
        configuration.HTTPMaximumConnectionsPerHost = 4;

        _session = [NSURLSession sessionWithConfiguration:configuration];
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

    if (size == 0) return @"";

    char *machine = malloc(size);
    if (!machine) return @"";

    NSString *identifier = @"";

    if (sysctlbyname("hw.machine", machine, &size, NULL, 0) == 0) {
        identifier = [NSString stringWithUTF8String:machine] ?: @"";
    }

    free(machine);
    return identifier;
}

+ (NSString *)currentDeviceFamily {
    return [[self currentDeviceIdentifier] hasPrefix:@"iPad"]
        ? @"iPad" : @"iPhone";
}

#pragma mark - HTTP

- (void)requestURL:(NSString *)url
        completion:(void (^)(id json, BOOL success, NSString *error))completion {

    NSURL *URL = [NSURL URLWithString:url];

    if (!URL) {
        if (completion) completion(nil, NO, @"Invalid URL");
        return;
    }

    NSMutableURLRequest *request =
    [NSMutableURLRequest requestWithURL:URL];

    request.HTTPMethod = @"GET";
    request.timeoutInterval = 60;

    [request setValue:@"application/json"
   forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task =
    [self.session dataTaskWithRequest:request
                    completionHandler:^(NSData *data,
                                        NSURLResponse *response,
                                        NSError *error) {

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;

        if (error) {
            if (completion) completion(nil, NO, error.localizedDescription);
            return;
        }

        if (!data || http.statusCode < 200 || http.statusCode >= 300) {
            NSString *message =
            [NSString stringWithFormat:@"HTTP %ld",
             (long)http.statusCode];

            if (completion) completion(nil, NO, message);
            return;
        }

        NSError *jsonError = nil;

        id json =
        [NSJSONSerialization JSONObjectWithData:data
                                        options:NSJSONReadingFragmentsAllowed
                                          error:&jsonError];

        if (jsonError || !json) {
            if (completion) {
                completion(nil, NO,
                           jsonError.localizedDescription ?: @"Invalid JSON");
            }
            return;
        }

        if (completion) completion(json, YES, nil);
    }];

    [task resume];
}

- (NSString *)escapedPath:(NSString *)value {
    return [value stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPathAllowedCharacterSet]] ?: value;
}

#pragma mark - JSON Helpers

- (NSArray *)arrayFromJSON:(id)json {
    if ([json isKindOfClass:[NSArray class]]) {
        return json;
    }

    if (![json isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    NSDictionary *dictionary = json;

    for (NSString *key in @[
        @"data", @"devices", @"firmwares", @"releases",
        @"items", @"results", @"versions"
    ]) {
        id value = dictionary[key];

        if ([value isKindOfClass:[NSArray class]]) {
            return value;
        }
    }

    return @[];
}

- (NSString *)stringValue:(id)value {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) {
        return [value stringValue];
    }
    return nil;
}

- (NSString *)firstStringIn:(NSDictionary *)dictionary
                       keys:(NSArray<NSString *> *)keys {
    for (NSString *key in keys) {
        NSString *value = [self stringValue:dictionary[key]];
        if (value.length > 0) return value;
    }
    return nil;
}

- (BOOL)boolValueFrom:(NSDictionary *)dictionary
                 keys:(NSArray<NSString *> *)keys
             fallback:(BOOL)fallback {
    for (NSString *key in keys) {
        id value = dictionary[key];

        if ([value respondsToSelector:@selector(boolValue)]) {
            return [value boolValue];
        }

        if ([value isKindOfClass:[NSString class]]) {
            NSString *lower = [value lowercaseString];

            if ([lower isEqualToString:@"true"] ||
                [lower isEqualToString:@"yes"] ||
                [lower isEqualToString:@"beta"]) return YES;

            if ([lower isEqualToString:@"false"] ||
                [lower isEqualToString:@"no"]) return NO;
        }
    }

    return fallback;
}

#pragma mark - Device Normalization

- (NSString *)familyForIdentifier:(NSString *)identifier
                         fallback:(NSString *)fallback {
    if ([identifier hasPrefix:@"iPhone"]) return @"iPhone";
    if ([identifier hasPrefix:@"iPad"]) return @"iPad";

    if ([fallback isEqualToString:@"iPhone"] ||
        [fallback isEqualToString:@"iPad"]) {
        return fallback;
    }

    return nil;
}

- (NSDictionary *)normalizeIPSWDevice:(NSDictionary *)item {
    NSString *name = [self firstStringIn:item keys:@[@"name", @"deviceName"]];
    NSString *identifier = [self firstStringIn:item
                                           keys:@[@"identifier", @"productType", @"product_type"]];

    NSString *family = [self familyForIdentifier:identifier
                                        fallback:[self firstStringIn:item
                                                               keys:@[@"product_type", @"type"]]];

    if (!name.length || !identifier.length || !family.length) return nil;

    NSMutableDictionary *device = [NSMutableDictionary dictionary];

    device[@"name"] = name;
    device[@"identifier"] = identifier;
    device[@"product_type"] = family;

    NSString *board = [self firstStringIn:item
                                    keys:@[@"boardconfig", @"boardConfig", @"board"]];

    if (board) device[@"boardconfig"] = board;

    id models = item[@"models"] ?: item[@"modelNumbers"];

    if ([models isKindOfClass:[NSArray class]]) {
        device[@"models"] = models;
    } else if ([models isKindOfClass:[NSString class]]) {
        device[@"models"] = @[models];
    }

    NSArray *copyKeys = @[
        @"introduction", @"launch_os_version", @"apple_cpu",
        @"platform", @"screen", @"cellular", @"imageurl",
        @"apple_image", @"support_id"
    ];

    for (NSString *key in copyKeys) {
        id value = item[key];
        if (value && value != [NSNull null]) device[key] = value;
    }

    return device;
}

- (NSArray *)normalizeAppleDBDevices:(id)json {
    NSMutableArray *raw = [NSMutableArray array];

    if ([json isKindOfClass:[NSArray class]]) {
        [raw addObjectsFromArray:json];
    } else if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = json;

        id nested = dict[@"devices"] ?: dict[@"data"];

        if ([nested isKindOfClass:[NSArray class]]) {
            [raw addObjectsFromArray:nested];
        } else if ([nested isKindOfClass:[NSDictionary class]]) {
            [raw addObjectsFromArray:[nested allValues]];
        } else {
            for (id key in dict) {
                id value = dict[key];

                if (![value isKindOfClass:[NSDictionary class]]) continue;

                NSMutableDictionary *record = [value mutableCopy];

                if (!record[@"identifier"] && !record[@"key"]) {
                    record[@"identifier"] = key;
                }

                [raw addObject:record];
            }
        }
    }

    NSMutableArray *result = [NSMutableArray array];

    for (id item in raw) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *record = item;

        NSString *identifier =
        [self firstStringIn:record
                       keys:@[@"identifier", @"key", @"device",
                              @"productType", @"product_type"]];

        NSString *family =
        [self familyForIdentifier:identifier
                         fallback:[self firstStringIn:record
                                                keys:@[@"type", @"deviceType",
                                                       @"product_type"]]];

        if (!identifier.length || !family.length) continue;

        NSString *name =
        [self firstStringIn:record
                       keys:@[@"name", @"deviceName", @"marketingName"]];

        if (!name.length) name = identifier;

        NSMutableDictionary *device = [NSMutableDictionary dictionary];

        device[@"name"] = name;
        device[@"identifier"] = identifier;
        device[@"product_type"] = family;

        NSString *board =
        [self firstStringIn:record
                       keys:@[@"board", @"boardconfig", @"boardConfig",
                              @"board_id", @"boardID"]];

        if (board) device[@"boardconfig"] = board;

        id models = record[@"models"] ?: record[@"modelNumbers"];

        if ([models isKindOfClass:[NSArray class]]) {
            device[@"models"] = models;
        } else if ([models isKindOfClass:[NSString class]]) {
            device[@"models"] = @[models];
        }

        [result addObject:device];
    }

    return result;
}

#pragma mark - Device Catalog

- (NSArray<NSDictionary *> *)devicesForFamily:(NSString *)family {
    NSArray *devices =
    [[self prefs] arrayForKey:@"DIMCatalogDevices"];

    NSMutableArray *result = [NSMutableArray array];

    for (NSDictionary *device in devices) {
        if (![device isKindOfClass:[NSDictionary class]]) continue;

        if ([device[@"product_type"] isEqualToString:family]) {
            [result addObject:device];
        }
    }

    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                     NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];

    return result;
}

- (NSDictionary *)deviceForIdentifier:(NSString *)identifier {
    if (!identifier.length) return nil;

    for (NSDictionary *device in
         [[self prefs] arrayForKey:@"DIMCatalogDevices"]) {

        if ([device[@"identifier"] isEqualToString:identifier]) {
            return device;
        }
    }

    return nil;
}

#pragma mark - Merge Device Sources

- (NSArray *)mergeDeviceSources:(NSArray *)sources {
    NSMutableDictionary *unique = [NSMutableDictionary dictionary];

    for (NSArray *source in sources) {
        for (NSDictionary *device in source) {
            NSString *identifier = device[@"identifier"];
            if (!identifier.length) continue;

            NSMutableDictionary *existing =
            [unique[identifier] mutableCopy] ?: [NSMutableDictionary dictionary];

            for (NSString *key in device) {
                id value = device[key];

                if (!existing[key] ||
                    ([existing[key] isKindOfClass:[NSString class]] &&
                     [existing[key] length] == 0)) {
                    existing[key] = value;
                }
            }

            unique[identifier] = existing;
        }
    }

    return [unique allValues];
}

#pragma mark - Firmware Cache

- (NSString *)firmwareCacheKey:(NSString *)identifier {
    NSString *safe =
    [identifier stringByReplacingOccurrencesOfString:@","
                                           withString:@"_"];

    return [@"DIMFirmware_" stringByAppendingString:safe];
}

- (NSArray<NSDictionary *> *)firmwaresForDevice:(NSString *)identifier {
    NSArray *items =
    [[self prefs] arrayForKey:[self firmwareCacheKey:identifier]];

    return [items isKindOfClass:[NSArray class]] ? items : @[];
}

- (void)refreshFirmwaresForDevice:(NSString *)identifier
                       completion:(void (^)(BOOL success, NSString *message))completion {

    if (!identifier.length) {
        if (completion) completion(NO, @"Invalid device identifier.");
        return;
    }

    NSString *url =
    [NSString stringWithFormat:@"%@/firmware/%@",
     DIMIPSWBase, [self escapedPath:identifier]];

    [self requestURL:url completion:^(id json, BOOL success, NSString *error) {

        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(NO,
                        [NSString stringWithFormat:
                         @"IPSW firmware request failed: %@", error ?: @"Unknown error"]);
                }
            });
            return;
        }

        NSArray *source = [self arrayFromJSON:json];
        NSMutableArray *result = [NSMutableArray array];

        for (NSDictionary *firmware in source) {
            if (![firmware isKindOfClass:[NSDictionary class]]) continue;

            NSString *version =
            [self firstStringIn:firmware keys:@[@"version", @"osVersion"]];

            NSString *build =
            [self firstStringIn:firmware keys:@[@"buildid", @"buildId", @"build"]];

            if (!version.length || !build.length) continue;

            NSMutableDictionary *entry = [NSMutableDictionary dictionary];

            entry[@"version"] = version;
            entry[@"build"] = build;
            entry[@"compatible"] = @YES;
            entry[@"source"] = @"IPSW.info";
            entry[@"is_beta"] = @NO;

            id signedValue = firmware[@"signed"];
            if (signedValue) entry[@"signed"] = signedValue;

            NSString *date =
            [self firstStringIn:firmware keys:@[@"releasedate", @"releaseDate"]];

            if (date) entry[@"release_date"] = date;

            NSString *download =
            [self firstStringIn:firmware keys:@[@"url", @"ipsw_url"]];

            if (download) entry[@"url"] = download;

            [result addObject:entry];
        }

        [result sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                         NSDictionary *b) {
            return [b[@"version"] compare:a[@"version"]
                                  options:NSNumericSearch];
        }];

        NSUserDefaults *prefs = [self prefs];

        [prefs setObject:result
                  forKey:[self firmwareCacheKey:identifier]];

        [prefs synchronize];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(YES,
                    [NSString stringWithFormat:
                     @"Loaded %lu IPSW builds for %@.",
                     (unsigned long)result.count, identifier]);
            }
        });
    }];
}

#pragma mark - AppleDB OS Parsing

- (BOOL)isBetaRecord:(NSDictionary *)record
             version:(NSString *)version {
    BOOL explicitBeta =
    [self boolValueFrom:record
                   keys:@[@"beta", @"isBeta", @"is_beta",
                          @"preRelease", @"prerelease"]
               fallback:NO];

    if (explicitBeta) return YES;

    NSString *channel =
    [[self firstStringIn:record
                    keys:@[@"releaseType", @"release_type",
                           @"channel", @"type", @"status"]] lowercaseString];

    if ([channel containsString:@"beta"] ||
        [channel containsString:@"developer"] ||
        [channel containsString:@"public beta"] ||
        [channel containsString:@"rc"]) {
        return YES;
    }

    NSString *lowerVersion = [version lowercaseString];

    return [lowerVersion containsString:@"beta"] ||
           [lowerVersion containsString:@"developer"] ||
           [lowerVersion containsString:@"rc"];
}

- (NSArray *)deviceIdentifiersFromRecord:(NSDictionary *)record {
    id devices = record[@"devices"] ?: record[@"compatibleDevices"];

    if (![devices isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *identifiers = [NSMutableArray array];

    for (id item in (NSArray *)devices) {
        if ([item isKindOfClass:[NSString class]]) {
            [identifiers addObject:item];
        } else if ([item isKindOfClass:[NSDictionary class]]) {
            NSString *identifier =
            [self firstStringIn:item
                           keys:@[@"identifier", @"key", @"device",
                                  @"productType", @"product_type"]];

            if (identifier) [identifiers addObject:identifier];
        }
    }

    return identifiers;
}

- (NSArray *)normalizeAppleDBOS:(id)json {
    NSArray *raw = [self arrayFromJSON:json];

    if (raw.count == 0 && [json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = json;

        for (NSString *key in @[@"ios", @"iOS", @"releases"]) {
            id value = dict[key];
            if ([value isKindOfClass:[NSArray class]]) {
                raw = value;
                break;
            }
        }

        if (raw.count == 0) {
            NSMutableArray *values = [NSMutableArray array];

            for (id key in dict) {
                id value = dict[key];

                if ([value isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary *record = [value mutableCopy];

                    if (!record[@"build"]) {
                        NSString *keyString = [self stringValue:key];
                        NSArray *parts = [keyString componentsSeparatedByString:@";"];

                        if (parts.count > 1) {
                            record[@"osStr"] = parts[0];
                            record[@"build"] = parts[1];
                        }
                    }

                    [values addObject:record];
                }
            }

            raw = values;
        }
    }

    NSMutableDictionary *unique = [NSMutableDictionary dictionary];

    for (id item in raw) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *record = item;

        NSString *osString =
        [self firstStringIn:record
                       keys:@[@"osStr", @"osType", @"name", @"platform"]];

        NSString *version =
        [self firstStringIn:record
                       keys:@[@"version", @"osVersion", @"marketingVersion"]];

        NSString *build =
        [self firstStringIn:record
                       keys:@[@"build", @"buildId", @"buildid", @"BuildID"]];

        if (!osString.length || !version.length || !build.length) continue;

        NSString *family = nil;
        NSString *lowerOS = [osString lowercaseString];

        if ([lowerOS containsString:@"ipados"]) {
            family = @"iPad";
        } else if ([lowerOS isEqualToString:@"ios"] ||
                   [lowerOS containsString:@"iphone os"]) {
            family = @"iPhone";
        }

        if (!family) continue;

        BOOL beta = [self isBetaRecord:record version:version];

        NSArray *devices = [self deviceIdentifiersFromRecord:record];

        NSString *key =
        [NSString stringWithFormat:@"%@|%@|%@", family, version, build];

        NSMutableDictionary *entry =
        [unique[key] mutableCopy] ?: [NSMutableDictionary dictionary];

        entry[@"version"] = version;
        entry[@"build"] = build;
        entry[@"family"] = family;
        entry[@"is_beta"] = @(beta);
        entry[@"compatible_devices"] = devices;
        entry[@"source"] = @"AppleDB";

        if (record[@"signed"]) entry[@"signed"] = record[@"signed"];

        NSString *date =
        [self firstStringIn:record
                       keys:@[@"released", @"releaseDate", @"release_date",
                              @"date"]];

        if (date) entry[@"release_date"] = date;

        unique[key] = entry;
    }

    NSArray *result = [unique allValues];

    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                                   NSDictionary *b) {
        NSComparisonResult versionResult =
        [b[@"version"] compare:a[@"version"] options:NSNumericSearch];

        if (versionResult != NSOrderedSame) return versionResult;

        return [b[@"build"] compare:a[@"build"] options:NSNumericSearch];
    }];
}

#pragma mark - Global Version Catalog

- (NSArray<NSDictionary *> *)versionsForFamily:(NSString *)family {
    NSString *key =
    [family isEqualToString:@"iPad"]
    ? @"DIMAppleDB_iPadOS"
    : @"DIMAppleDB_iOS";

    NSArray *versions = [[self prefs] arrayForKey:key];

    return [versions isKindOfClass:[NSArray class]] ? versions : @[];
}

- (BOOL)build:(NSDictionary *)build
supportsDevice:(NSString *)identifier {

    NSArray *devices = build[@"compatible_devices"];

    if (![devices isKindOfClass:[NSArray class]] || devices.count == 0) {
        return NO;
    }

    for (NSString *candidate in devices) {
        if (![candidate isKindOfClass:[NSString class]]) continue;

        if ([candidate isEqualToString:identifier]) return YES;

        NSString *normalized =
        [[candidate componentsSeparatedByString:@"-"] firstObject];

        if ([normalized isEqualToString:identifier]) return YES;
    }

    return NO;
}

- (NSArray<NSDictionary *> *)buildsForDevice:(NSString *)identifier
                                  includeBetas:(BOOL)includeBetas
                            allowIncompatible:(BOOL)allowIncompatible {

    NSDictionary *device = [self deviceForIdentifier:identifier];
    NSString *family = device[@"product_type"];

    if (!family) {
        family = [identifier hasPrefix:@"iPad"] ? @"iPad" : @"iPhone";
    }

    NSMutableDictionary *unique = [NSMutableDictionary dictionary];

    // Device-specific IPSW builds
    for (NSDictionary *firmware in [self firmwaresForDevice:identifier]) {
        if ([firmware[@"is_beta"] boolValue] && !includeBetas) continue;

        NSString *version = firmware[@"version"];
        NSString *build = firmware[@"build"];

        if (!version.length || !build.length) continue;

        NSString *key = [NSString stringWithFormat:@"%@|%@", version, build];

        NSMutableDictionary *entry = [firmware mutableCopy];
        entry[@"compatible"] = @YES;
        entry[@"family"] = family;

        unique[key] = entry;
    }

    // Global AppleDB builds
    for (NSDictionary *build in [self versionsForFamily:family]) {
        if ([build[@"is_beta"] boolValue] && !includeBetas) continue;

        BOOL compatible = [self build:build supportsDevice:identifier];

        if (!compatible && !allowIncompatible) continue;

        NSString *version = build[@"version"];
        NSString *buildID = build[@"build"];

        if (!version.length || !buildID.length) continue;

        NSString *key =
        [NSString stringWithFormat:@"%@|%@", version, buildID];

        NSMutableDictionary *entry =
        [unique[key] mutableCopy] ?: [NSMutableDictionary dictionary];

        for (NSString *field in build) {
            entry[field] = build[field];
        }

        entry[@"compatible"] = @(compatible);

        unique[key] = entry;
    }

    NSArray *result = [unique allValues];

    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                                   NSDictionary *b) {
        NSComparisonResult versionResult =
        [b[@"version"] compare:a[@"version"] options:NSNumericSearch];

        if (versionResult != NSOrderedSame) return versionResult;

        return [b[@"build"] compare:a[@"build"] options:NSNumericSearch];
    }];
}

#pragma mark - Catalog Refresh

- (void)refreshCatalogWithCompletion:
(void (^)(BOOL success, NSString *message))completion {

    dispatch_group_t group = dispatch_group_create();

    __block id ipswPhones = nil;
    __block id ipswPads = nil;
    __block id appleDevices = nil;
    __block id appleOS = nil;

    __block NSString *phoneError = nil;
    __block NSString *padError = nil;
    __block NSString *deviceError = nil;
    __block NSString *osError = nil;

    NSArray *urls = @[
        [NSString stringWithFormat:
         @"%@/devices?type=iPhone&format=full", DIMIPSWBase],

        [NSString stringWithFormat:
         @"%@/devices?type=iPad&format=full", DIMIPSWBase],

        [NSString stringWithFormat:
         @"%@/device/main.json", DIMAppleDBBase],

        [NSString stringWithFormat:
         @"%@/ios/main.json", DIMAppleDBBase]
    ];

    for (NSUInteger index = 0; index < urls.count; index++) {
        dispatch_group_enter(group);

        [self requestURL:urls[index]
              completion:^(id json, BOOL success, NSString *error) {

            switch (index) {
                case 0:
                    ipswPhones = json;
                    phoneError = success ? nil : error;
                    break;
                case 1:
                    ipswPads = json;
                    padError = success ? nil : error;
                    break;
                case 2:
                    appleDevices = json;
                    deviceError = success ? nil : error;
                    break;
                case 3:
                    appleOS = json;
                    osError = success ? nil : error;
                    break;
            }

            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{

        NSMutableArray *phoneRecords = [NSMutableArray array];
        NSMutableArray *padRecords = [NSMutableArray array];

        for (id item in [self arrayFromJSON:ipswPhones]) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;

            NSDictionary *device = [self normalizeIPSWDevice:item];
            if ([device[@"product_type"] isEqualToString:@"iPhone"]) {
                [phoneRecords addObject:device];
            }
        }

        for (id item in [self arrayFromJSON:ipswPads]) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;

            NSDictionary *device = [self normalizeIPSWDevice:item];
            if ([device[@"product_type"] isEqualToString:@"iPad"]) {
                [padRecords addObject:device];
            }
        }

        NSArray *appleDeviceRecords =
        [self normalizeAppleDBDevices:appleDevices];

        NSMutableArray *applePhoneRecords = [NSMutableArray array];
        NSMutableArray *applePadRecords = [NSMutableArray array];

        for (NSDictionary *device in appleDeviceRecords) {
            if ([device[@"product_type"] isEqualToString:@"iPhone"]) {
                [applePhoneRecords addObject:device];
            } else if ([device[@"product_type"] isEqualToString:@"iPad"]) {
                [applePadRecords addObject:device];
            }
        }

        NSArray *mergedPhones =
        [self mergeDeviceSources:@[phoneRecords, applePhoneRecords]];

        NSArray *mergedPads =
        [self mergeDeviceSources:@[padRecords, applePadRecords]];

        NSArray *mergedDevices =
        [self mergeDeviceSources:@[mergedPhones, mergedPads]];

        NSArray *appleBuilds = [self normalizeAppleDBOS:appleOS];

        NSMutableArray *iosBuilds = [NSMutableArray array];
        NSMutableArray *ipadosBuilds = [NSMutableArray array];

        for (NSDictionary *build in appleBuilds) {
            if ([build[@"family"] isEqualToString:@"iPhone"]) {
                [iosBuilds addObject:build];
            } else if ([build[@"family"] isEqualToString:@"iPad"]) {
                [ipadosBuilds addObject:build];
            }
        }

        NSUserDefaults *prefs = [self prefs];

        if (mergedDevices.count > 0) {
            [prefs setObject:mergedDevices forKey:@"DIMCatalogDevices"];
        }

        if (iosBuilds.count > 0) {
            [prefs setObject:iosBuilds forKey:@"DIMAppleDB_iOS"];
        }

        if (ipadosBuilds.count > 0) {
            [prefs setObject:ipadosBuilds forKey:@"DIMAppleDB_iPadOS"];
        }

        NSDictionary *status = @{
            @"IPSW_iPhone": @(phoneError == nil),
            @"IPSW_iPad": @(padError == nil),
            @"AppleDB_Devices": @(deviceError == nil),
            @"AppleDB_OS": @(osError == nil)
        };

        [prefs setObject:status forKey:@"DIMCatalogSourceStatus"];

        BOOL anySourceSucceeded =
        (phoneError == nil) || (padError == nil) ||
        (deviceError == nil) || (osError == nil);

        BOOL hasUsableData =
        mergedDevices.count > 0 || iosBuilds.count > 0 || ipadosBuilds.count > 0;

        NSString *message =
        [NSString stringWithFormat:
         @"Devices: %lu (iPhone %lu, iPad %lu)\n"
         "iOS builds: %lu\n"
         "iPadOS builds: %lu\n"
         "Sources: IPSW iPhone %@, IPSW iPad %@, AppleDB devices %@, AppleDB OS %@",
         (unsigned long)mergedDevices.count,
         (unsigned long)mergedPhones.count,
         (unsigned long)mergedPads.count,
         (unsigned long)iosBuilds.count,
         (unsigned long)ipadosBuilds.count,
         phoneError ? @"ERROR" : @"OK",
         padError ? @"ERROR" : @"OK",
         deviceError ? @"ERROR" : @"OK",
         osError ? @"ERROR" : @"OK"];

        if (hasUsableData) {
            [prefs setObject:[NSDate date] forKey:@"DIMCatalogLastUpdated"];
            [prefs setObject:message forKey:@"DIMCatalogStatus"];
        } else {
            [prefs setObject:@"No usable catalog data received. Previous cache preserved."
                      forKey:@"DIMCatalogStatus"];
        }

        [prefs synchronize];

        if (completion) {
            completion(anySourceSucceeded && hasUsableData,
                       hasUsableData ? message :
                       @"Catalog update failed. Check network and source status.");
        }
    });
}

#pragma mark - Statistics

- (NSDictionary *)catalogStatistics {
    NSUserDefaults *prefs = [self prefs];

    NSArray *devices = [prefs arrayForKey:@"DIMCatalogDevices"] ?: @[];
    NSArray *ios = [prefs arrayForKey:@"DIMAppleDB_iOS"] ?: @[];
    NSArray *ipados = [prefs arrayForKey:@"DIMAppleDB_iPadOS"] ?: @[];

    NSUInteger betaIOS = 0;
    NSUInteger betaIPadOS = 0;

    for (NSDictionary *item in ios) {
        if ([item[@"is_beta"] boolValue]) betaIOS++;
    }

    for (NSDictionary *item in ipados) {
        if ([item[@"is_beta"] boolValue]) betaIPadOS++;
    }

    return @{
        @"devices": @(devices.count),
        @"ios": @(ios.count),
        @"ipados": @(ipados.count),
        @"ios_beta": @(betaIOS),
        @"ipados_beta": @(betaIPadOS)
    };
}

- (NSDate *)lastUpdateDate {
    return [[self prefs] objectForKey:@"DIMCatalogLastUpdated"];
}

- (NSString *)catalogStatus {
    return [[self prefs] stringForKey:@"DIMCatalogStatus"]
        ?: @"Catalog has not been updated yet.";
}

@end
