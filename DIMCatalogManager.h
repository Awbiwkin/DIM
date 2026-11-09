
#import <Foundation/Foundation.h>

@interface DIMCatalogManager : NSObject

+ (instancetype)sharedManager;

- (void)refreshCatalogWithCompletion:(void (^)(BOOL success, NSString *message))completion;

- (NSArray<NSDictionary *> *)devicesForFamily:(NSString *)family;

- (NSArray<NSDictionary *> *)versionsForFamily:(NSString *)family;

- (NSDate *)lastUpdateDate;

- (NSString *)catalogStatus;

@end
