# ============================================================
# Makefile — TwitchSevenTV (substrate-free, sideload)
# ============================================================

ARCHS = arm64
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

# ── Nom du dylib ──
LIBRARY_NAME = TwitchSevenTV

# ── Fichiers source ──
TwitchSevenTV_FILES = \
    TweakSevenTV.m \
    SevenTVManager.m \
    SevenTVURLProtocol.m \
    SevenTVSettingsController.m \
    SevenTVLogsController.m

# ── Options de compilation ──
TwitchSevenTV_CFLAGS = \
    -fobjc-arc \
    -I$(THEOS_PROJECT_DIR) \
    -Wno-unused-variable \
    -Wno-unused-function

# ── Options linker ──
TwitchSevenTV_LDFLAGS = \
    -Wl,-no_warn_inits \
    -Wl,-w

# ── Frameworks Apple ──
TwitchSevenTV_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	@echo "✅ Compilation terminée (substrate-free)."
	@echo "📦 Le .dylib est prêt pour injection dans l'IPA."
