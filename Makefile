# Абсолютно надёжное определение THEOS для любых сред
ifndef THEOS
THEOS := $(shell pwd)/theos
endif

include $(THEOS)/makefiles/common.mk

TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

TWEAK_NAME = DeviceIdentityManager

DeviceIdentityManager_FILES = \
    Core/DIMManager.m \
    Hooks/DeviceIdentity.x \
    Hooks/GPSSpoof.x \
    Hooks/StatusBarSpoof.x

DeviceIdentityManager_CFLAGS = -fobjc-arc -I. -ICore
DeviceIdentityManager_FRAMEWORKS = UIKit CoreLocation CoreGraphics SystemConfiguration

include $(THEOS_MAKEFILE_PATH)/tweak.mk

SUBPROJECTS += Preferences
include $(THEOS)/makefiles/aggregate.mk
