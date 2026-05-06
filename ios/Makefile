# Makefile for SWCampus Checkpoint Floating Window Tweak
# Target: iOS 16.5 Dopamine (rootless) jailbreak
# Build: make package

ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0

THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SWCampus

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SWRunCheckpointHUD

SWRunCheckpointHUD_FILES = Tweak.x SWRunFloatingView.m SWRunRoutePlanner.m SWRunRouteRealPath.m SWRunSimulator.m
SWRunCheckpointHUD_CFLAGS = -fobjc-arc
SWRunCheckpointHUD_FRAMEWORKS = UIKit CoreGraphics Foundation CoreLocation MapKit CoreMotion
SWRunCheckpointHUD_PRIVATE_FRAMEWORKS = 
SWRunCheckpointHUD_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SWCampus || true"
