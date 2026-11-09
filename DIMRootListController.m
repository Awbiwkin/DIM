
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface DIMRootListController : PSListController
@end

@implementation DIMRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers =
            [self loadSpecifiersFromPlistName:@"Root"
                                       target:self];
    }

    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
