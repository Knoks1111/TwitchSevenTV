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
# ⚠️  RÈGLE: tout nouveau fichier .m DOIT être ajouté ici, sinon
#    le linker échoue avec "Undefined symbol: __OBJC_CLASS_$_NomDeLaClasse"
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
# -Wl,-no_warn_inits  → supprime "static initializer found" causé par
#                        __attribute__((constructor)) dans TweakSevenTV.m.
#                        C'est normal pour un dylib injecté, pas une erreur.
# -Wl,-w             → supprime les warnings linker obsolètes comme
#                        "-multiply_defined is obsolete" (vieux flag Theos).
TwitchSevenTV_LDFLAGS = \
    -Wl,-no_warn_inits \
    -Wl,-w

# ── Frameworks Apple ──
TwitchSevenTV_FRAMEWORKS = UIKit Foundation QuartzCore ImageIO

# ── Pas de bundle ID cible (injection via IPA patching) ──

include $(THEOS_MAKE_PATH)/library.mk

after-stage::
	@echo "✅ Compilation terminée (substrate-free)."
	@echo "📦 Le .dylib est prêt pour injection dans l'IPA."
