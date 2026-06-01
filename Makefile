# ============================================================
# Makefile — TwitchSevenTV (substrate-free, sideload)
# ============================================================
# Utilise library.mk au lieu de tweak.mk → pas de lien Substrate

ARCHS = arm64
TARGET = iphone:clang:16.5:14.0

include $(THEOS)/makefiles/common.mk

# ── Nom du dylib ──
LIBRARY_NAME = TwitchSevenTV

# ── Fichiers source ──
# TweakSevenTV.m remplace TweakSevenTV.xm (plus de Logos/Substrate)
TwitchSevenTV_FILES = \
    TweakSevenTV.m \
    SevenTVManager.m \
    SevenTVURLProtocol.m \
    SevenTVSettingsController.m

# ── Options de compilation ──
TwitchSevenTV_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR) -Wno-unused-variable -Wno-unused-function

# ── Frameworks Apple ──
TwitchSevenTV_FRAMEWORKS = UIKit Foundation

# ── Pas de bundle ID cible (injection via IPA patching) ──

include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	@echo "✅ Compilation terminée (substrate-free)."
	@echo "📦 Le .dylib est prêt pour injection dans l'IPA."
