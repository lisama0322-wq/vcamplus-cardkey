INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME     = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamplus

vcamplus_FILES      = Tweak.xm vcam_friend_js.mm
vcamplus_LDFLAGS    = -Wl,-x -Wl,-S -lz -lsubstrate
vcamplus_FRAMEWORKS = AVFoundation CoreMedia CoreVideo CoreImage Foundation UIKit QuartzCore IOSurface ImageIO Security
vcamplus_ARCHS      = arm64 arm64e
vcamplus_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new -O2

include $(THEOS_MAKE_PATH)/tweak.mk
