
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface DIMAppProfilesController : UITableViewController
@end

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

- (void)openAppProfiles {
    DIMAppProfilesController *controller =
        [[DIMAppProfilesController alloc]
            initWithStyle:UITableViewStyleInsetGrouped];

    controller.title = @"App Profiles";

    UINavigationController *navigation =
        self.navigationController;

    if (navigation) {
        [navigation pushViewController:controller
                              animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc]
                initWithRootViewController:controller];

        wrapper.modalPresentationStyle =
            UIModalPresentationFullScreen;

        [self presentViewController:wrapper
                           animated:YES
                         completion:nil];
    }
}

@end
