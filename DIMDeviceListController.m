
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface DIMDeviceListController : PSListController
@end

@implementation DIMDeviceListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Device" target:self];
    }
    return _specifiers;
}

@end
