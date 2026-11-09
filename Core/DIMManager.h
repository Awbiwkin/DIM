#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface DIMManager : NSObject

@property (nonatomic, assign) BOOL globalEnabled;
@property (nonatomic, assign) BOOL allowNonStandardCombinations;

+ (instancetype)sharedManager;
- (void)loadSettings;
- (NSDictionary *)settingsForBundleID:(NSString *)bundleID;

// Device Identity
- (NSString *)spoofedModelForBundleID:(NSString *)bundleID;
- (NSString *)spoofedProductTypeForBundleID:(NSString *)bundleID;
- (NSString *)spoofedSystemVersionForBundleID:(NSString *)bundleID;
- (NSString *)spoofedBuildVersionForBundleID:(NSString *)bundleID;

// GPS
- (BOOL)isGPSSpoofingEnabledForBundleID:(NSString *)bundleID;
- (CLLocationCoordinate2D)spoofedCoordinatesForBundleID:(NSString *)bundleID;

// Network & Carrier
- (BOOL)isCarrierSpoofingEnabled;
- (NSString *)fakeCarrierNameForSIM:(NSInteger)simSlot;
- (NSInteger)fakeSignalBarsForSIM:(NSInteger)simSlot;
- (BOOL)isFakeWiFiEnabled;
- (NSString *)fakeWiFiSSID;

@end
