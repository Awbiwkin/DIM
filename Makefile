# Явно задаем путь к theos для GitHub Actions и локальной сборки
THEOS ?= $(CURDIR)/theos

TARGET := iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

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
include $(THEOS_MAKEFILE_PATH)/aggregate.mk
