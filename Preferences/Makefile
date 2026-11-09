TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DIMPreferences

DIMPreferences_FILES = DIMRootListController.m
DIMPreferences_FRAMEWORKS = UIKit Preferences
DIMPreferences_PRIVATE_FRAMEWORKS = Preferences
DIMPreferences_INSTALL_PATH = /Library/PreferenceBundles
DIMPreferences_CFLAGS = -fobjc-arc -I../Core

include $(THEOS_MAKEFILE_PATH)/bundle.mk
