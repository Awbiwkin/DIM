
#import <Foundation/Foundation.h>

@interface DIMCatalogManager : NSObject

+ (instancetype)sharedManager;

+ (NSString *)currentDeviceIdentifier;

+ (NSString *)currentDeviceFamily;

- (void)refreshCatalogWithCompletion:(void (^)(BOOL success, NSString *message))completion;

- (void)refreshFirmwaresForDevice:(NSString *)identifier
                       completion:(void (^)(BOOL success, NSString *message))completion;

- (NSArray<NSDictionary *> *)devicesForFamily:(NSString *)family;

- (NSArray<NSDictionary *> *)firmwaresForDevice:(NSString *)identifier;

- (NSArray<NSDictionary *> *)versionsForFamily:(NSString *)family;

- (NSDictionary *)deviceForIdentifier:(NSString *)identifier;

- (NSDate *)lastUpdateDate;

- (NSString *)catalogStatus;

@end
