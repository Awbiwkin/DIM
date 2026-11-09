#import <UIKit/UIKit.h>
#import "DIMManager.h"

// На iOS 15 отображение Строки состояния обрабатывается через SystemStatus / UIStatusBarServer
%hook _UIStatusBarDataCellularEntry

- (void)setStringValue:(NSString *)stringValue {
    DIMManager *dim = [DIMManager sharedManager];
    if ([dim isCarrierSpoofingEnabled]) {
        %orig([dim fakeCarrierNameForSIM:1]);
    } else {
        %orig(stringValue);
    }
}

%end

%hook _UIStatusBarDataWifiEntry

- (void)setSsid:(NSString *)ssid {
    DIMManager *dim = [DIMManager sharedManager];
    if ([dim isFakeWiFiEnabled]) {
        %orig([dim fakeWiFiSSID]);
    } else {
        %orig(ssid);
    }
}

%end
