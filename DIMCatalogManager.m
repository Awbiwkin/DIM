
#import <Foundation/Foundation.h>

@interface DIMCatalogManager : NSObject

+ (instancetype)sharedManager;
+ (NSString *)currentDeviceIdentifier;
+ (NSString *)currentDeviceFamily;

- (void)refreshCatalogWithCompletion:(void (^)(BOOL success, NSString *message))completion;

- (void)refreshFirmwaresForDevice:(NSString *)identifier
                       completion:(void (^)(BOOL success, NSString *message))completion;

- (NSArray<NSDictionary *> *)devicesForFamily:(NSString *)family;
- (NSDictionary *)deviceForIdentifier:(NSString *)identifier;

- (NSArray<NSDictionary *> *)firmwaresForDevice:(NSString *)identifier;
- (NSArray<NSDictionary *> *)versionsForFamily:(NSString *)family;

- (NSArray<NSDictionary *> *)buildsForDevice:(NSString *)identifier
                                  includeBetas:(BOOL)includeBetas
                            allowIncompatible:(BOOL)allowIncompatible;

- (NSDate *)lastUpdateDate;
- (NSString *)catalogStatus;
- (NSDictionary *)catalogStatistics;

@end
