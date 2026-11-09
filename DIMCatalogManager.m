
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
    NSString *identifier = [self currentDeviceIdentifier];
    if ([identifier hasPrefix:@"iPad"]) return @"iPad";
    if ([identifier hasPrefix:@"iPhone"]) return @"iPhone";
    return @"iPhone";
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
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

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
            [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode];
            if (completion) completion(nil, NO, message);
            return;
        }

        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data
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
    NSCharacterSet *allowed =
    [NSCharacterSet characterSetWithCharactersInString:
     @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];

    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed]
        ?: value;
}

#pragma mark - JSON Helpers

- (NSArray *)arrayFromJSON:(id)json {
    if ([json isKindOfClass:NSArray.class]) return json;
    if (![json isKindOfClass:NSDictionary.class]) return @[];

    NSDictionary *dictionary = json;

    for (NSString *key in @[
        @"data", @"devices", @"firmwares", @"releases",
        @"items", @"results", @"versions"
    ]) {
        id value = dictionary[key];
        if ([value isKindOfClass:NSArray.class]) return value;
    }

    return @[];
}

- (NSString *)stringValue:(id)value {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:NSString.class]) return value;

    if ([value respondsToSelector:@selector(stringValue)]) {
        return [value stringValue];
    }

    return nil;
}

- (NSString *)firstStringIn:(NSDictionary *)dictionary
                       keys:(NSArray<NSString *> *)keys {
    for (NSString *key in keys) {
        NSString *value = [self stringValue:dictionary[key]];
        if (value.length) return value;
    }
    return nil;
}

- (BOOL)boolValueFrom:(NSDictionary *)dictionary
                 keys:(NSArray<NSString *> *)keys
             fallback:(BOOL)fallback {
    for (NSString *key in keys) {
        id value = dictionary[key];
        if (!value || value == [NSNull null]) continue;

        if ([value respondsToSelector:@selector(boolValue)]) {
            return [value boolValue];
        }

        if ([value isKindOfClass:NSString.class]) {
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

- (NSArray *)stringArrayFromValue:(id)value {
    if (!value || value == [NSNull null]) return @[];

    if ([value isKindOfClass:NSString.class]) {
        return [value length] ? @[value] : @[];
    }

    if (![value isKindOfClass:NSArray.class]) return @[];

    NSMutableArray *result = [NSMutableArray array];

    for (id item in (NSArray *)value) {
        if ([item isKindOfClass:NSString.class] && [item length]) {
            [result addObject:item];
        } else if ([item isKindOfClass:NSDictionary.class]) {
            NSString *candidate =
            [self firstStringIn:item
                           keys:@[@"identifier", @"key", @"device",
                                  @"productType", @"product_type",
                                  @"model", @"number"]];
            if (candidate.length) [result addObject:candidate];
        }
    }

    return result;
}

// Все настоящие ProductType из записи каталога (у одного устройства их может быть
// несколько: Wi-Fi и Cellular версии).
- (NSArray<NSString *> *)productTypesFromRecord:(NSDictionary *)record {
    NSMutableOrderedSet *found = [NSMutableOrderedSet orderedSet];

    for (NSString *key in @[@"identifier", @"identifiers", @"productType",
                            @"product_type", @"deviceIdentifier", @"device"]) {
        id raw = record[key];
        NSArray *candidates = nil;

        if ([raw isKindOfClass:NSString.class]) {
            candidates = @[raw];
        } else if ([raw isKindOfClass:NSArray.class]) {
            candidates = raw;
        } else {
            continue;
        }

        for (id candidate in candidates) {
            if ([candidate isKindOfClass:NSString.class] &&
                [self familyForIdentifier:candidate]) {
                [found addObject:candidate];
            }
        }
    }

    return found.array;
}

- (NSString *)deviceIdentifierFromRecord:(NSDictionary *)record {
    return [[self productTypesFromRecord:record] firstObject];
}

// Настоящий ProductType выглядит так: iPhone16,2 / iPad13,4.
// Раньше проверялся только префикс "iPhone"/"iPad", и в список попадали аксессуары
// ("iPhone Silicone Case with MagSafe", "iPad Smart Folio" и т.п.).
- (NSString *)familyForIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return nil;

    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:@"^(iPhone|iPad)[0-9]+,[0-9]+$"
                                 options:0
                                   error:nil];
    });

    NSUInteger matches =
    [expression numberOfMatchesInString:identifier
                                options:0
                                  range:NSMakeRange(0, identifier.length)];

    if (matches != 1) return nil;

    return [identifier hasPrefix:@"iPad"] ? @"iPad" : @"iPhone";
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

#pragma mark - Model Number / Region Parsing

- (void)appendModelValue:(id)value
                 region:(NSString *)inheritedRegion
                 toList:(NSMutableArray *)list {

    if (!value || value == [NSNull null]) return;

    if ([value isKindOfClass:NSString.class]) {
        NSString *model = [value stringByTrimmingCharactersInSet:
                           NSCharacterSet.whitespaceAndNewlineCharacterSet];

        if (!model.length) return;

        NSDictionary *entry = @{
            @"model": model,
            @"region": inheritedRegion.length ? inheritedRegion : @""
        };

        if (![list containsObject:entry]) [list addObject:entry];
        return;
    }

    if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value) {
            [self appendModelValue:item region:inheritedRegion toList:list];
        }
        return;
    }

    if (![value isKindOfClass:NSDictionary.class]) return;

    NSDictionary *dictionary = value;

    NSString *model =
    [self firstStringIn:dictionary
                   keys:@[@"modelNumber", @"model_number", @"number",
                          @"identifier", @"partNumber", @"part_number",
                          @"model", @"value", @"sku"]];

    NSString *region =
    [self firstStringIn:dictionary
                   keys:@[@"region", @"market", @"country",
                          @"salesRegion", @"sales_region",
                          @"variant", @"distribution"]];

    if (!region.length) region = inheritedRegion;

    if (model.length) {
        NSDictionary *entry = @{
            @"model": model,
            @"region": region ?: @""
        };

        if (![list containsObject:entry]) [list addObject:entry];
    } else {
        for (NSString *key in dictionary) {
            id nested = dictionary[key];

            if ([nested isKindOfClass:NSArray.class] ||
                [nested isKindOfClass:NSDictionary.class]) {
                [self appendModelValue:nested
                               region:(region.length ? region : key)
                               toList:list];
            }
        }
    }
}

- (NSArray *)modelVariantsFromRecord:(NSDictionary *)record {
    NSMutableArray *result = [NSMutableArray array];

    for (NSString *key in @[
        @"models", @"modelNumbers", @"model_numbers",
        @"model", @"modelNumber", @"model_number",
        @"partNumbers", @"part_numbers", @"sku"
    ]) {
        id value = record[key];
        if (value && value != [NSNull null]) {
            [self appendModelValue:value region:nil toList:result];
        }
    }

    return result;
}

- (NSArray *)uniqueModelNumbersFromVariants:(NSArray *)variants {
    NSMutableOrderedSet *numbers = [NSMutableOrderedSet orderedSet];

    for (NSDictionary *variant in variants) {
        NSString *model = variant[@"model"];
        if (model.length) [numbers addObject:model];
    }

    return numbers.array;
}

#pragma mark - Device Normalization

- (NSDictionary *)normalizeIPSWDevice:(NSDictionary *)item {
    NSString *identifier =
    [self firstStringIn:item
                   keys:@[@"identifier", @"productType", @"product_type"]];

    NSString *family = [self familyForIdentifier:identifier];

    // Не допускаем аксессуары и сторонние записи.
    if (!family) return nil;

    NSString *name =
    [self firstStringIn:item keys:@[@"name", @"deviceName", @"marketingName"]];

    if (!name.length) return nil;

    NSMutableDictionary *device = [NSMutableDictionary dictionary];
    device[@"name"] = name;
    device[@"identifier"] = identifier;
    device[@"product_type"] = family;

    NSString *board =
    [self firstStringIn:item
                   keys:@[@"boardconfig", @"boardConfig", @"board",
                          @"board_id", @"boardID"]];

    if (board.length) device[@"boardconfig"] = board;

    NSArray *variants = [self modelVariantsFromRecord:item];
    if (variants.count) {
        device[@"model_variants"] = variants;
        device[@"models"] = [self uniqueModelNumbersFromVariants:variants];
    }

    for (NSString *key in @[
        @"introduction", @"launch_os_version", @"apple_cpu",
        @"platform", @"screen", @"cellular", @"support_id"
    ]) {
        id value = item[key];
        if (value && value != [NSNull null]) device[key] = value;
    }

    return device;
}

- (NSArray *)normalizeAppleDBDevices:(id)json {
    NSMutableArray *raw = [NSMutableArray array];

    if ([json isKindOfClass:NSArray.class]) {
        [raw addObjectsFromArray:json];
    } else if ([json isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = json;
        id nested = dict[@"devices"] ?: dict[@"data"];

        if ([nested isKindOfClass:NSArray.class]) {
            [raw addObjectsFromArray:nested];
        } else if ([nested isKindOfClass:NSDictionary.class]) {
            for (id key in nested) {
                id value = nested[key];
                if (![value isKindOfClass:NSDictionary.class]) continue;

                NSMutableDictionary *record = [value mutableCopy];
                if (!record[@"identifier"] && !record[@"key"]) {
                    record[@"identifier"] = key;
                }
                [raw addObject:record];
            }
        } else {
            for (id key in dict) {
                id value = dict[key];
                if (![value isKindOfClass:NSDictionary.class]) continue;

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
        if (![item isKindOfClass:NSDictionary.class]) continue;

        NSDictionary *record = item;
        NSArray<NSString *> *identifiers = [self productTypesFromRecord:record];

        // Строго только реальные ProductType iPhone/iPad.
        if (!identifiers.count) continue;

        for (NSString *identifier in identifiers) {
        NSString *family = [self familyForIdentifier:identifier];
        if (!family) continue;

        NSString *name =
        [self firstStringIn:record
                       keys:@[@"name", @"deviceName", @"marketingName"]];

        if (!name.length) name = identifier;

        NSMutableDictionary *device = [NSMutableDictionary dictionary];
        device[@"name"] = name;
        device[@"identifier"] = identifier;
        device[@"product_type"] = family;

        id rawBoard = record[@"board"] ?:
                      record[@"boardconfig"] ?:
                      record[@"boardConfig"] ?:
                      record[@"board_id"] ?:
                      record[@"boardID"];

        NSString *board = nil;

        if ([rawBoard isKindOfClass:NSString.class]) {
            board = rawBoard;
        } else if ([rawBoard isKindOfClass:NSArray.class]) {
            NSMutableArray *boardParts = [NSMutableArray array];

            for (id item in (NSArray *)rawBoard) {
                NSString *part = [self stringValue:item];

                if (!part.length && [item isKindOfClass:NSDictionary.class]) {
                    part = [self firstStringIn:item
                                          keys:@[@"board", @"name",
                                                 @"identifier", @"id"]];
                }

                if (part.length) [boardParts addObject:part];
            }

            if (boardParts.count) {
                board = [boardParts componentsJoinedByString:@", "];
            }
        } else if ([rawBoard isKindOfClass:NSDictionary.class]) {
            NSMutableArray *boardParts = [NSMutableArray array];

            for (id key in rawBoard) {
                NSString *part = [self stringValue:rawBoard[key]];
                if (!part.length) part = [self stringValue:key];
                if (part.length) [boardParts addObject:part];
            }

            if (boardParts.count) {
                board = [boardParts componentsJoinedByString:@", "];
            }
        }

        if (board.length) device[@"boardconfig"] = board;

        NSArray *variants = [self modelVariantsFromRecord:record];

        if (variants.count) {
            device[@"model_variants"] = variants;
            device[@"models"] = [self uniqueModelNumbersFromVariants:variants];
        }

        NSString *introduced =
        [self firstStringIn:record
                       keys:@[@"released", @"releaseDate", @"introduction"]];

        if (introduced.length) device[@"introduction"] = introduced;

        [result addObject:device];
        }
    }

    return result;
}

#pragma mark - Device Catalog

- (NSArray<NSDictionary *> *)devicesForFamily:(NSString *)family {
    NSArray *devices = [[self prefs] arrayForKey:@"DIMCatalogDevices"];
    NSMutableArray *result = [NSMutableArray array];

    for (NSDictionary *device in devices) {
        if (![device isKindOfClass:NSDictionary.class]) continue;

        NSString *real = [self familyForIdentifier:device[@"identifier"]];

        if (real && [real isEqualToString:family]) {
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
            if (![self familyForIdentifier:identifier]) continue;

            NSMutableDictionary *existing =
            [unique[identifier] mutableCopy] ?: [NSMutableDictionary dictionary];

            for (NSString *key in device) {
                id value = device[key];
                id oldValue = existing[key];

                if (!oldValue ||
                    ([oldValue isKindOfClass:NSString.class] &&
                     [oldValue length] == 0)) {
                    existing[key] = value;
                    continue;
                }

                if ([key isEqualToString:@"models"] ||
                    [key isEqualToString:@"model_variants"]) {
                    NSMutableOrderedSet *merged =
                    [NSMutableOrderedSet orderedSetWithArray:
                     ([oldValue isKindOfClass:NSArray.class] ? oldValue : @[])];

                    if ([value isKindOfClass:NSArray.class]) {
                        [merged addObjectsFromArray:value];
                    }

                    existing[key] = merged.array;
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

    return [items isKindOfClass:NSArray.class] ? items : @[];
}

- (void)refreshFirmwaresForDevice:(NSString *)identifier
                       completion:(void (^)(BOOL success, NSString *message))completion {

    if (![self familyForIdentifier:identifier]) {
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
                         @"IPSW firmware request failed: %@",
                         error ?: @"Unknown error"]);
                }
            });
            return;
        }

        NSArray *source = [self arrayFromJSON:json];
        NSMutableDictionary *unique = [NSMutableDictionary dictionary];

        for (NSDictionary *firmware in source) {
            if (![firmware isKindOfClass:NSDictionary.class]) continue;

            NSString *version =
            [self firstStringIn:firmware keys:@[@"version", @"osVersion"]];

            NSString *build =
            [self firstStringIn:firmware
                           keys:@[@"buildid", @"buildId", @"build"]];

            if (!version.length || !build.length) continue;

            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"version"] = version;
            entry[@"build"] = build;
            entry[@"compatible"] = @YES;
            entry[@"source"] = @"IPSW.info";

            BOOL beta =
            [self boolValueFrom:firmware
                           keys:@[@"beta", @"isBeta", @"is_beta"]
                       fallback:NO];

            entry[@"is_beta"] = @(beta);

            id signedValue = firmware[@"signed"];
            if (signedValue && signedValue != [NSNull null]) {
                entry[@"signed"] = signedValue;
            }

            NSString *date =
            [self firstStringIn:firmware
                           keys:@[@"releasedate", @"releaseDate",
                                  @"release_date"]];

            if (date) entry[@"release_date"] = date;

            NSString *download =
            [self firstStringIn:firmware keys:@[@"url", @"ipsw_url"]];

            if (download) entry[@"url"] = download;

            NSString *key = [NSString stringWithFormat:@"%@|%@", version, build];
            unique[key] = entry;
        }

        NSArray *result = [[unique allValues]
            sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                            NSDictionary *b) {
            NSComparisonResult comparison =
            [b[@"version"] compare:a[@"version"] options:NSNumericSearch];

            if (comparison != NSOrderedSame) return comparison;
            return [b[@"build"] compare:a[@"build"] options:NSNumericSearch];
        }];

        NSUserDefaults *prefs = [self prefs];
        [prefs setObject:result forKey:[self firmwareCacheKey:identifier]];
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

- (BOOL)isBetaRecord:(NSDictionary *)record version:(NSString *)version {
    BOOL explicitBeta =
    [self boolValueFrom:record
                   keys:@[@"beta", @"isBeta", @"is_beta",
                          @"preRelease", @"prerelease", @"rc"]
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

    NSString *lower = [version lowercaseString];

    return [lower containsString:@"beta"] ||
           [lower containsString:@"developer"] ||
           [lower containsString:@"rc"];
}

- (NSArray *)deviceIdentifiersFromRecord:(NSDictionary *)record {
    NSMutableOrderedSet *identifiers = [NSMutableOrderedSet orderedSet];

    // AppleDB: deviceMap — плоский список ProductType,
    // devices — словарь, где ключи это ProductType.
    // Раньше читался только devices, и у новых сборок (OTA) он пустой,
    // поэтому свежие версии считались несовместимыми и пропадали из списка.
    for (NSString *key in @[@"deviceMap", @"devices", @"compatibleDevices"]) {
        id devices = record[key];

        if ([devices isKindOfClass:NSArray.class]) {
            for (id item in devices) {
                if ([item isKindOfClass:NSString.class]) {
                    if ([self familyForIdentifier:item]) {
                        [identifiers addObject:item];
                    }
                } else if ([item isKindOfClass:NSDictionary.class]) {
                    NSString *identifier = [self deviceIdentifierFromRecord:item];
                    if (identifier.length) [identifiers addObject:identifier];
                }
            }
        } else if ([devices isKindOfClass:NSDictionary.class]) {
            for (id deviceKey in devices) {
                if ([deviceKey isKindOfClass:NSString.class] &&
                    [self familyForIdentifier:deviceKey]) {
                    [identifiers addObject:deviceKey];
                }
            }
        }
    }

    return identifiers.array;
}

- (NSArray *)normalizeAppleDBOS:(id)json {
    NSMutableArray *raw = [NSMutableArray array];

    if ([json isKindOfClass:NSArray.class]) {
        [raw addObjectsFromArray:json];
    } else if ([json isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = json;

        NSArray *knownKeys = @[@"ios", @"iOS", @"releases", @"data"];

        for (NSString *key in knownKeys) {
            id value = dict[key];
            if ([value isKindOfClass:NSArray.class]) {
                [raw addObjectsFromArray:value];
                break;
            }
        }

        if (raw.count == 0) {
            for (id key in dict) {
                id value = dict[key];
                if (![value isKindOfClass:NSDictionary.class]) continue;

                NSMutableDictionary *record = [value mutableCopy];

                NSString *keyString = [self stringValue:key];
                NSArray *parts = [keyString componentsSeparatedByString:@";"];

                if (parts.count >= 2) {
                    if (!record[@"osStr"]) record[@"osStr"] = parts[0];
                    if (!record[@"build"]) record[@"build"] = parts[1];
                }

                [raw addObject:record];
            }
        }
    }

    NSMutableDictionary *unique = [NSMutableDictionary dictionary];

    for (id item in raw) {
        if (![item isKindOfClass:NSDictionary.class]) continue;

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

        NSString *lowerOS = [osString lowercaseString];
        NSString *family = nil;

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

        NSString *darwinVersion =
        [self firstStringIn:record keys:@[@"darwinVersion", @"darwin"]];

        if ([self isDarwinString:darwinVersion]) {
            entry[@"darwin"] = darwinVersion;
        }

        if (record[@"signed"] && record[@"signed"] != [NSNull null]) {
            entry[@"signed"] = record[@"signed"];
        }

        NSString *date =
        [self firstStringIn:record
                       keys:@[@"released", @"releaseDate", @"release_date",
                              @"date"]];

        if (date) entry[@"release_date"] = date;

        unique[key] = entry;
    }

    return [[unique allValues]
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                        NSDictionary *b) {
        NSComparisonResult comparison =
        [b[@"version"] compare:a[@"version"] options:NSNumericSearch];

        if (comparison != NSOrderedSame) return comparison;
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
    return [versions isKindOfClass:NSArray.class] ? versions : @[];
}

- (BOOL)build:(NSDictionary *)build supportsDevice:(NSString *)identifier {
    NSArray *devices = build[@"compatible_devices"];
    if (![devices isKindOfClass:NSArray.class]) return NO;

    for (NSString *candidate in devices) {
        if (![candidate isKindOfClass:NSString.class]) continue;

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

    if (![self familyForIdentifier:identifier]) return @[];

    NSDictionary *device = [self deviceForIdentifier:identifier];
    NSString *family = device[@"product_type"];

    if (!family) family = [identifier hasPrefix:@"iPad"] ? @"iPad" : @"iPhone";

    NSMutableDictionary *unique = [NSMutableDictionary dictionary];

    // IPSW.info: builds explicitly returned for this device.
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

    // AppleDB: global build catalog, filtered by actual compatible devices.
    for (NSDictionary *build in [self versionsForFamily:family]) {
        if ([build[@"is_beta"] boolValue] && !includeBetas) continue;

        BOOL compatible = [self build:build supportsDevice:identifier];
        if (!compatible && !allowIncompatible) continue;

        NSString *version = build[@"version"];
        NSString *buildID = build[@"build"];

        if (!version.length || !buildID.length) continue;

        NSString *key = [NSString stringWithFormat:@"%@|%@", version, buildID];
        NSMutableDictionary *entry =
        [unique[key] mutableCopy] ?: [NSMutableDictionary dictionary];

        [entry addEntriesFromDictionary:build];
        entry[@"compatible"] = @(compatible);

        unique[key] = entry;
    }

    return [[unique allValues]
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                        NSDictionary *b) {
        NSComparisonResult comparison =
        [b[@"version"] compare:a[@"version"] options:NSNumericSearch];

        if (comparison != NSOrderedSame) return comparison;
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
    __block id appleOSPad = nil;

    __block NSString *phoneError = nil;
    __block NSString *padError = nil;
    __block NSString *deviceError = nil;
    __block NSString *osError = nil;

    NSArray *urls = @[
        [NSString stringWithFormat:@"%@/devices?type=iPhone&format=full",
         DIMIPSWBase],
        [NSString stringWithFormat:@"%@/devices?type=iPad&format=full",
         DIMIPSWBase],
        [NSString stringWithFormat:@"%@/device/main.json", DIMAppleDBBase],
        [NSString stringWithFormat:@"%@/ios/iOS/main.json", DIMAppleDBBase],
        [NSString stringWithFormat:@"%@/ios/iPadOS/main.json", DIMAppleDBBase]
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
                case 4:
                    appleOSPad = json;
                    if (!success && !osError) osError = error;
                    break;
            }
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSMutableArray *phoneRecords = [NSMutableArray array];
        NSMutableArray *padRecords = [NSMutableArray array];

        for (id item in [self arrayFromJSON:ipswPhones]) {
            if (![item isKindOfClass:NSDictionary.class]) continue;

            NSDictionary *device = [self normalizeIPSWDevice:item];
            if ([device[@"product_type"] isEqualToString:@"iPhone"]) {
                [phoneRecords addObject:device];
            }
        }

        for (id item in [self arrayFromJSON:ipswPads]) {
            if (![item isKindOfClass:NSDictionary.class]) continue;

            NSDictionary *device = [self normalizeIPSWDevice:item];
            if ([device[@"product_type"] isEqualToString:@"iPad"]) {
                [padRecords addObject:device];
            }
        }

        NSArray *appleDeviceRecords =
        [self normalizeAppleDBDevices:appleDevices];

        NSMutableArray *applePhones = [NSMutableArray array];
        NSMutableArray *applePads = [NSMutableArray array];

        for (NSDictionary *device in appleDeviceRecords) {
            if ([device[@"product_type"] isEqualToString:@"iPhone"]) {
                [applePhones addObject:device];
            } else if ([device[@"product_type"] isEqualToString:@"iPad"]) {
                [applePads addObject:device];
            }
        }

        NSArray *mergedPhones =
        [self mergeDeviceSources:@[phoneRecords, applePhones]];

        NSArray *mergedPads =
        [self mergeDeviceSources:@[padRecords, applePads]];

        NSArray *mergedDevices =
        [self mergeDeviceSources:@[mergedPhones, mergedPads]];

        NSMutableArray *appleBuilds =
        [NSMutableArray arrayWithArray:[self normalizeAppleDBOS:appleOS]];

        [appleBuilds addObjectsFromArray:[self normalizeAppleDBOS:appleOSPad]];

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

        // Не затираем рабочий кеш пустым ответом.
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
            [prefs setObject:
             @"No usable catalog data received. Previous cache preserved."
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
