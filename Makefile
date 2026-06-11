# ============================================================
# Makefile — TwitchSevenTV (substrate-free, sideload)
# ============================================================

ARCHS = arm64
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

# ── Nom du dylib ──
LIBRARY_NAME = TwitchSevenTV

# ── Headers ──
# SevenTVAdBlock.h  (nouveau — clés NSUserDefaults AdBlock/Proxy)

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

# ── Dylibs externes (TwitchControl) ──
EXTRA_DYLIBS = \
    TwitchControl0_0_5.dylib \
    zxPluginsInject.dylib \
    sideloadFixerLol.dylib

# ── Options linker ──
TwitchSevenTV_LDFLAGS = \
    -Wl,-no_warn_inits \
    -Wl,-w

# ── Frameworks Apple ──
TwitchSevenTV_FRAMEWORKS = UIKit Foundation QuartzCore Network AVFoundation

include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	@for dylib in $(EXTRA_DYLIBS); do \
		if [ -f "$$dylib" ]; then \
			cp "$$dylib" "$(THEOS_STAGING_DIR)/" && echo "  OK $$dylib"; \
		else \
			echo "  MISSING $$dylib"; \
		fi; \
	done
	@echo "✅ Compilation terminée (substrate-free)."
	@echo "📦 Le .dylib est prêt pour injection dans l'IPA."
