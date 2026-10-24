ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide
INSTALL_TARGET_PROCESSES =

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ScarletXProbe
ScarletXProbe_FILES = Tweak.xm ProbePanel.m ProbeDriveOAuthTest.m ProbePrivateUpdate.m
ScarletXProbe_FRAMEWORKS = Foundation UIKit AuthenticationServices Security
ScarletXProbe_CFLAGS = -fobjc-arc
ScarletXProbe_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
