# ============================================================
# Makefile - Instructions de compilation pour Theos
# ============================================================
# Theos est l'outil standard pour compiler des tweaks iOS.
# Ce fichier dit à Theos quoi compiler et comment.

# Architecture: arm64 uniquement (tous les iPhones depuis 2013)
ARCHS = arm64

# Cible: iOS 14.0 minimum, compilé avec clang, SDK iOS 16.5
TARGET = iphone:clang:16.5:14.0

# Inclure les règles communes de Theos
include $(THEOS)/makefiles/common.mk

# ── Nom du tweak ──
TWEAK_NAME = TwitchSevenTV

# ── Fichiers source à compiler ──
TwitchSevenTV_FILES = \
    TweakSevenTV.xm \
    SevenTVManager.m \
    SevenTVURLProtocol.m \
    SevenTVSettingsController.m

# ── Options de compilation ──
# -fobjc-arc : Active la gestion automatique de la mémoire (ARC)
TwitchSevenTV_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR) -Wno-unused-variable -Wno-unused-function

# ── Frameworks Apple utilisés ──
TwitchSevenTV_FRAMEWORKS = UIKit Foundation

# ── Application cible ──
# "tv.twitch.live" est le bundle ID de l'app Twitch officielle iOS
# Pour une IPA modifiée avec bundle ID différent, changer cette valeur
# Note: pour injection dans IPA (pas jailbreak), cette ligne est ignorée
TwitchSevenTV_BUNDLE_ID = tv.twitch.live

# Inclure les règles de compilation pour tweak
include $(THEOS_MAKE_PATH)/tweak.mk

# ── Étape post-compilation: copier le .deb dans le dossier output ──
after-stage::
	@echo "✅ Compilation terminée. Le fichier .dylib est prêt pour injection."
	@echo "📦 Le fichier .deb se trouve dans packages/"
