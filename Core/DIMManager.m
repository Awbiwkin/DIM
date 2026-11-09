#import "DIMManager.h"

#define PREFS_PATH @"/var/jb/var/mobile/Library/Preferences/com.dim.preferences.plist"

@interface DIMManager ()
@property (nonatomic, strong) NSDictionary *prefs;
@end

@implementation DIMManager

+ (instancetype)sharedManager {
    static DIMManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
        [shared loadSettings];
    });
    return shared;
}

- (void)loadSettings {
    _prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    _globalEnabled = [_prefs[@"enabled"] boolValue];
    _allowNonStandardCombinations = [_prefs[@"allowNonStandard"] boolValue];
}

- (NSDictionary *)settingsForBundleID:(NSString *)bundleID {
    if (!self.globalEnabled || !bundleID) return nil;
    
    NSDictionary *perApp = _prefs[@"perAppProfiles"];
    NSDictionary *appSettings = perApp[bundleID];
    
    NSString *mode = _prefs[@"profileMode"] ?: @"Global";
    if ([mode isEqualToString:@"PerApp"] && !appSettings) {
        return nil;
    }
    if ([mode isEqualToString:@"Both"] && appSettings && [appSettings[@"overrideGlobal"] boolValue]) {
        return appSettings;
    }
    
    return _prefs; // Возврат глобальных настроек по умолчанию
}

- (NSString *)spoofedModelForBundleID:(NSString *)bundleID {
    NSDictionary *config = [self settingsForBundleID:bundleID];
    return config[@"targetModelName"] ?: @"iPhone 14 Pro Max";
}

- (NSString *)spoofedProductTypeForBundleID:(NSString *)bundleID {
    NSDictionary *config = [self settingsForBundleID:bundleID];
    return config[@"targetProductType"] ?: @"iPhone15,3";
}

- (NSString *)spoofedSystemVersionForBundleID:(NSString *)bundleID {
    NSDictionary *config = [self settingsForBundleID:bundleID];
    return config[@"targetSystemVersion"] ?: @"18.0";
}

- (NSString *)spoofedBuildVersionForBundleID:(NSString *)bundleID {
    NSDictionary *config = [self settingsForBundleID:bundleID];
    return config[@"targetBuildVersion"] ?: @"22A3354";
}

- (BOOL)isGPSSpoofingEnabledForBundleID:(NSString *)bundleID {
    NSDictionary *config = [self settingsForBundleID:bundleID];
    return [config[@"gpsSpoofEnabled"] boolValue];
}

- (CLLocationCoordinate2D)spoofedCoordinatesForBundleID:(NSString *)bundleID {
    NSDictionary *config = [self settingsForBundleID:bundleID];
    double lat = [config[@"gpsLatitude"] doubleValue];
    double lon = [config[@"gpsLongitude"] doubleValue];
    return CLLocationCoordinate2DMake(lat, lon);
}

- (BOOL)isCarrierSpoofingEnabled {
    return [_prefs[@"carrierSpoofEnabled"] boolValue];
}

- (NSString *)fakeCarrierNameForSIM:(NSInteger)simSlot {
    if (simSlot == 2) return _prefs[@"sim2CarrierName"] ?: @"au";
    return _prefs[@"sim1CarrierName"] ?: @"docomo";
}

- (NSInteger)fakeSignalBarsForSIM:(NSInteger)simSlot {
    if (simSlot == 2) return [_prefs[@"sim2Bars"] integerValue];
    return [_prefs[@"sim1Bars"] integerValue];
}

- (BOOL)isFakeWiFiEnabled {
    return [_prefs[@"fakeWiFiEnabled"] boolValue];
}

- (NSString *)fakeWiFiSSID {
    return _prefs[@"fakeWiFiSSID"] ?: @"docomo Wi-Fi";
}

@end
