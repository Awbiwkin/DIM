#import <CoreLocation/CoreLocation.h>
#import "DIMManager.h"

%hook CLLocationManager

- (CLLocation *)location {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    DIMManager *dim = [DIMManager sharedManager];
    
    if ([dim isGPSSpoofingEnabledForBundleID:bundleID]) {
        CLLocationCoordinate2D coord = [dim spoofedCoordinatesForBundleID:bundleID];
        return [[CLLocation alloc] initWithCoordinate:coord
                                             altitude:15.0
                                   horizontalAccuracy:5.0
                                     verticalAccuracy:5.0
                                            timestamp:[NSDate date]];
    }
    return %orig;
}

%end

%hook CLLocation

- (CLLocationCoordinate2D)coordinate {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    DIMManager *dim = [DIMManager sharedManager];
    
    if ([dim isGPSSpoofingEnabledForBundleID:bundleID]) {
        return [dim spoofedCoordinatesForBundleID:bundleID];
    }
    return %orig;
}

%end
