
THEOS_PACKAGE_SCHEME = rootless

ARCHS = arm64
TARGET = iphone:clang:latest:15.0

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DIMCore

DIMCore_FILES = Tweak.xm
DIMCore_CFLAGS = -fobjc-arc
DIMCore_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = DIMPreferences

DIMPreferences_FILES = DIMRootListController.m
DIMPreferences_FRAMEWORKS = UIKit
DIMPreferences_PRIVATE_FRAMEWORKS = Preferences
DIMPreferences_INSTALL_PATH = /Library/PreferenceBundles
DIMPreferences_RESOURCE_FILES = Root.plist

include $(THEOS_MAKE_PATH)/bundle.mk
