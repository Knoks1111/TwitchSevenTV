/*
 * TweakSevenTV.m  —  Substrate-FREE version
 *
 * Gère :
 *   - Injection du bouton 7TV dans la barre de chat (hijack bouton Bits)
 *   - Picker d'emotes 7TV (favoris + recherche)
 *   - Interception IRC WebSocket (ROOMSTATE → chargement emotes channel)
 *   - Interception GQL Twitch (broadcaster ID → chargement emotes channel)
 *   - Redirection CDN (SevenTVURLProtocol)
 *   - Section 7TV Settings dans les paramètres Twitch (AccountMenuViewController)
 *   - Tap logger de diagnostic
 */

#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVLogo.h"
#import "SevenTVSettingsController.h"
// Cle NSUserDefaults Auto Collect Channel Points
#define kTCLiveAutoCollectChannelPoints @"TCDBGLiveAutoCollectChannelPoints"

// ────────────────────────────────────────────────────────────
// MARK: - Clés associated objects
// ────────────────────────────────────────────────────────────

static const char kS7TVTextFieldTagged = 5;
static const char kS7TVEmoteRatioKey   = 9;   // associated object sur UIImage/objet animé → NSNumber(ratio)
static const char kS7TVBitsHijacked    = 6;
static const char kS7TVOrigSectionCount = 7;
static const char kS7TVShareHijacked   = 8;   // verrou orientation

// État global verrou d'orientation
static BOOL s_orientationLocked             = NO;
static UIInterfaceOrientationMask s_lockedOrientationMask = UIInterfaceOrientationMaskAll;


// ────────────────────────────────────────────────────────────
// MARK: - Helper swizzle
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle(Class targetClass,
                         Class sourceClass,
                         SEL   original,
                         SEL   swizzled) {
    if (!targetClass || !sourceClass) {
        [[SevenTVManager sharedManager] log:@"⚠️  swizzle ignoré (classe nil): %@",
         NSStringFromSelector(original)];
        return;
    }

    Method swizzledMethod = class_getInstanceMethod(sourceClass, swizzled);
    if (!swizzledMethod) {
        [[SevenTVManager sharedManager] log:@"⚠️  méthode swizzlée introuvable: %@",
         NSStringFromSelector(swizzled)];
        return;
    }
    class_addMethod(targetClass,
                    swizzled,
                    method_getImplementation(swizzledMethod),
                    method_getTypeEncoding(swizzledMethod));

    Method origMethod = class_getInstanceMethod(targetClass, original);
    if (!origMethod) {
        [[SevenTVManager sharedManager] log:@"⚠️  méthode originale introuvable sur %@: %@",
         NSStringFromClass(targetClass), NSStringFromSelector(original)];
        return;
    }

    Method swizzledOnTarget = class_getInstanceMethod(targetClass, swizzled);
    method_exchangeImplementations(origMethod, swizzledOnTarget);

    [[SevenTVManager sharedManager] log:@"✅ swizzle OK [%@] %@",
     NSStringFromClass(targetClass), NSStringFromSelector(original)];
}


// ────────────────────────────────────────────────────────────
// MARK: - Wrapper weak pour associated objects (brise les retain cycles)
// ────────────────────────────────────────────────────────────

// objc_setAssociatedObject ne supporte pas les weak refs nativement.
// On emballe la référence faible dans cet objet pour éviter le retain cycle
// bitsBtn (subview) → chatInputView (superview) qui empêche la libération
// de la vue au moment de la fermeture du stream.
@interface S7TVWeakRef : NSObject
@property (nonatomic, weak) id object;
+ (instancetype)refWithObject:(id)object;
@end
@implementation S7TVWeakRef
+ (instancetype)refWithObject:(id)object {
    S7TVWeakRef *r = [S7TVWeakRef new];
    r.object = object;
    return r;
}
@end


// ────────────────────────────────────────────────────────────
// MARK: - Helper dump KVC sécurisé (pour les logs 🎞)
// ────────────────────────────────────────────────────────────

// Vérifie quelles méthodes (getters/setters) une instance possède réellement,
// sans rien lire ni écrire — juste respondsToSelector:, donc zéro risque de crash.
static void s7tvLogResponds(id obj, NSArray<NSString *> *selectors, NSInteger sampleIdx, NSString *label) {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *selStr in selectors) {
        SEL sel = NSSelectorFromString(selStr);
        if ([obj respondsToSelector:sel]) [found addObject:selStr];
    }
    [mgr log:@"🎞[%ld]   %@ répond à: %@",
     (long)sampleIdx, label, found.count ? [found componentsJoinedByString:@", "] : @"(aucun)"];
}


// ────────────────────────────────────────────────────────────
// MARK: - Helper accès ivar objet sécurisé (par nom, pas d'offset)
// Lit un ivar de type objet ("@...") en cherchant par NOM via
// class_getInstanceVariable — aucun offset numérique en dur. Si le
// layout change entre versions de l'app, on récupère nil au lieu de
// lire un pointeur invalide (donc plus de risque d'EXC_BAD_ACCESS).
// ────────────────────────────────────────────────────────────

static id s7tv_getObjectIvar(id obj, const char *ivarName) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (!iv) return nil;
    const char *enc = ivar_getTypeEncoding(iv);
    // Sur les classes Swift, l'encodage runtime est souvent une chaîne VIDE même
    // pour de vrais ivars objet (CALayer, etc. — confirmé par dump : animatedImageLayer
    // existe bien mais enc="" ). On ne rejette que si le runtime connaît EXPLICITEMENT
    // un type non-objet (struct/scalar/etc.) — encodage vide = on tente quand même.
    if (enc && enc[0] != '\0' && enc[0] != '@') return nil;
    return object_getIvar(obj, iv);
}

// Relance startAnimating sur le ivar "animatedImageLayer" de l'ImageAttachmentLayer
// englobant, à intervalles réguliers (max ~1.5s), le temps que l'image GIF finisse
// de charger en arrière-plan. Piste retenue à la place du hook sur
// "imageLoadSubscriptions" (Combine), trop fragile à intercepter côté Swift.
// Filet de sécurité complémentaire au hook displayLayer: — logs throttlés (5 max
// de chaque type) maintenant que le comportement est confirmé.
static void s7tv_retryStartAnimatingStep(CALayer *outerLayer, NSInteger attemptsLeft, NSInteger maxAttempts) {
    static NSInteger s_exhaustedLogCount = 0;
    if (attemptsLeft <= 0) {
        if (outerLayer && s_exhaustedLogCount < 5) {
            s_exhaustedLogCount++;
            [[SevenTVManager sharedManager] log:[NSString stringWithFormat:
                @"🩻 retry startAnimating — épuisé sans confirmation de succès (log %ld/5)",
                (long)s_exhaustedLogCount]];
        }
        return;
    }
    if (!outerLayer) return;

    __weak CALayer *weakLayer = outerLayer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CALayer *layer = weakLayer;
        if (!layer || !layer.superlayer) return; // cellule recyclée / layer disparu

        id animLayer = s7tv_getObjectIvar(layer, "animatedImageLayer");
        SEL startSel = NSSelectorFromString(@"startAnimating");
        SevenTVManager *mgr = [SevenTVManager sharedManager];
        NSInteger attemptNum = maxAttempts - attemptsLeft + 1;

        static NSInteger s_retry1LogCount = 0;
        if (attemptNum == 1 && s_retry1LogCount < 5) {
            s_retry1LogCount++;
            if (animLayer) {
                [mgr log:[NSString stringWithFormat:
                    @"🩻 retry#1 — ivar animatedImageLayer trouvé, classe=%@, répond startAnimating=%@ (log %ld/5)",
                    NSStringFromClass(object_getClass(animLayer)),
                    [animLayer respondsToSelector:startSel] ? @"OUI" : @"NON", (long)s_retry1LogCount]];
            } else {
                [mgr log:[NSString stringWithFormat:
                    @"🩻 retry#1 — ivar animatedImageLayer INTROUVABLE (nil ou pas un objet) (log %ld/5)",
                    (long)s_retry1LogCount]];
            }
        }

        if (animLayer && [animLayer respondsToSelector:startSel]) {
            @try { ((void(*)(id,SEL))objc_msgSend)(animLayer, startSel); } @catch(...) {}
        }
        s7tv_retryStartAnimatingStep(layer, attemptsLeft - 1, maxAttempts);
    });
}

static void s7tv_retryStartAnimating(CALayer *outerLayer, NSInteger attempts) {
    s7tv_retryStartAnimatingStep(outerLayer, attempts, attempts);
}


// ────────────────────────────────────────────────────────────
// MARK: - Dump diagnostic ivars/méthodes (debug animation GIF)
// Tourne UNE SEULE FOIS (premier emote 7TV affiché) pour vérifier que
// les noms d'ivars/classes supposés (animatedImageLayer, etc.) sont
// corrects dans CETTE version de l'app, sans spammer les logs ensuite.
// ────────────────────────────────────────────────────────────

static void s7tv_dumpIvars(Class cls, NSString *label) {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    if (!cls) { [mgr log:[NSString stringWithFormat:@"🩻 %@ : classe nil", label]]; return; }
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    [mgr log:[NSString stringWithFormat:@"🩻 %@ (%@) — %u ivars:", label, NSStringFromClass(cls), count]];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *enc  = ivar_getTypeEncoding(ivars[i]);
        [mgr log:[NSString stringWithFormat:@"🩻   - %s : %s", name ?: "?", enc ?: "?"]];
    }
    if (ivars) free(ivars);
}

// Dump ivars AVEC leurs valeurs (objets uniquement) — utilisé pour chercher
// un identifiant (emoteID/URL/nom) directement lisible sur l'attachment,
// sans dépendre d'un matching par position (fragile).
static void s7tv_dumpIvarValues(id obj, NSString *label) {
    if (!obj) return;
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    Class cls = object_getClass(obj);
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    [mgr log:[NSString stringWithFormat:@"🩻 %@ (%@) — %u ivars (valeurs):", label, NSStringFromClass(cls), count]];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        const char *enc  = ivar_getTypeEncoding(ivars[i]);
        NSString *valStr = @"?";
        if (enc && enc[0] == '@') {
            @try {
                id val = object_getIvar(obj, ivars[i]);
                valStr = val ? [NSString stringWithFormat:@"%@", val] : @"nil";
            } @catch (...) { valStr = @"<erreur lecture>"; }
        } else if (enc) {
            valStr = [NSString stringWithFormat:@"(type %s, non-objet)", enc];
        }
        [mgr log:[NSString stringWithFormat:@"🩻   - %s [%s] = %@", name ?: "?", enc ?: "?", valStr]];
    }
    if (ivars) free(ivars);

    Class superCls = class_getSuperclass(cls);
    if (superCls && superCls != [NSObject class]) {
        unsigned int scount = 0;
        Ivar *sivars = class_copyIvarList(superCls, &scount);
        [mgr log:[NSString stringWithFormat:@"🩻 %@ → superclasse %@ — %u ivars (valeurs):", label, NSStringFromClass(superCls), scount]];
        for (unsigned int i = 0; i < scount; i++) {
            const char *name = ivar_getName(sivars[i]);
            const char *enc  = ivar_getTypeEncoding(sivars[i]);
            NSString *valStr = @"?";
            if (enc && enc[0] == '@') {
                @try {
                    id val = object_getIvar(obj, sivars[i]);
                    valStr = val ? [NSString stringWithFormat:@"%@", val] : @"nil";
                } @catch (...) { valStr = @"<erreur lecture>"; }
            } else if (enc) {
                valStr = [NSString stringWithFormat:@"(type %s, non-objet)", enc];
            }
            [mgr log:[NSString stringWithFormat:@"🩻   - %s [%s] = %@", name ?: "?", enc ?: "?", valStr]];
        }
        if (sivars) free(sivars);
    }
}

static void s7tv_dumpMethods(Class cls, NSString *label) {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    if (!cls) { [mgr log:[NSString stringWithFormat:@"🩻 %@ : classe nil", label]]; return; }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        [names addObject:NSStringFromSelector(method_getName(methods[i]))];
    }
    if (methods) free(methods);
    [mgr log:[NSString stringWithFormat:@"🩻 %@ (%@) — méthodes: %@",
        label, NSStringFromClass(cls), names.count ? [names componentsJoinedByString:@", "] : @"(aucune)"]];
}

static void s7tv_dumpAnimationArchitectureOnce(CALayer *outerLayer) {
    static BOOL s_dumped = NO;
    if (s_dumped || !outerLayer) return;
    s_dumped = YES;

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    Class outerCls = object_getClass(outerLayer);
    [mgr log:@"🩻 ━━━━━ DUMP architecture animation (une seule fois) ━━━━━"];
    s7tv_dumpIvars(outerCls, @"ImageAttachmentLayer (outer, trouvé via sublayer 'Animated')");

    id animLayer = s7tv_getObjectIvar(outerLayer, "animatedImageLayer");
    SEL startSel = NSSelectorFromString(@"startAnimating");
    if (animLayer) {
        [mgr log:[NSString stringWithFormat:@"🩻 ivar 'animatedImageLayer' trouvé → classe réelle: %@",
            NSStringFromClass(object_getClass(animLayer))]];
        [mgr log:[NSString stringWithFormat:@"🩻   répond à startAnimating: %@",
            [animLayer respondsToSelector:startSel] ? @"OUI" : @"NON"]];
        s7tv_dumpMethods(object_getClass(animLayer), @"objet de l'ivar animatedImageLayer");
    } else {
        [mgr log:@"🩻 ivar 'animatedImageLayer' INTROUVABLE sur l'ImageAttachmentLayer — le nom a peut-être changé"];
    }

    // Lire les autres ivars clés de l'ImageAttachmentLayer
    id staticLayer  = s7tv_getObjectIvar(outerLayer, "staticImageLayer");
    id currentLayer = s7tv_getObjectIvar(outerLayer, "currentImageLayer");
    id curDisplayMode = s7tv_getObjectIvar(outerLayer, "currentDisplayMode");

    [mgr log:[NSString stringWithFormat:@"🩻 ivar 'staticImageLayer'  → %@ (%p)",
        staticLayer ? NSStringFromClass(object_getClass(staticLayer)) : @"nil", staticLayer]];
    [mgr log:[NSString stringWithFormat:@"🩻 ivar 'animatedImageLayer'→ %@ (%p)",
        animLayer ? NSStringFromClass(object_getClass(animLayer)) : @"nil", animLayer]];
    [mgr log:[NSString stringWithFormat:@"🩻 ivar 'currentImageLayer' → %@ (%p)",
        currentLayer ? NSStringFromClass(object_getClass(currentLayer)) : @"nil", currentLayer]];
    [mgr log:[NSString stringWithFormat:@"🩻 ivar 'currentDisplayMode'→ %@",
        curDisplayMode ? [curDisplayMode description] : @"nil"]];

    // ⬇ Diagnostic clé : quel layer est réellement affiché ?
    if (currentLayer) {
        BOOL curIsAnimated = (currentLayer == animLayer);
        BOOL curIsStatic   = (currentLayer == staticLayer);
        [mgr log:[NSString stringWithFormat:
            @"🩻 currentImageLayer == animatedImageLayer : %@ | == staticImageLayer : %@",
            curIsAnimated ? @"✅ OUI (animé affiché)" : @"❌ NON",
            curIsStatic   ? @"✅ OUI (statique affiché)" : @"NON"]];
    } else {
        [mgr log:@"🩻 currentImageLayer nil — ivar absent ou nom changé"];
    }

    // Comparaison avec le sublayer détecté via containsString:@"Animated"
    for (CALayer *sub in outerLayer.sublayers) {
        if ([NSStringFromClass(object_getClass(sub)) containsString:@"Animated"]) {
            [mgr log:[NSString stringWithFormat:
                @"🩻 sublayer 'Animated' (trouvé via .sublayers) (%p) → classe: %@",
                sub, NSStringFromClass(object_getClass(sub))]];
            [mgr log:[NSString stringWithFormat:
                @"🩻   == animatedImageLayer(ivar): %@ | == currentImageLayer: %@",
                (sub == animLayer)   ? @"OUI" : @"NON",
                (sub == currentLayer)? @"OUI" : @"NON"]];
            [mgr log:[NSString stringWithFormat:
                @"🩻   frame: %@ | hidden: %@ | opacity: %.2f | superlayer: %@",
                NSStringFromCGRect(sub.frame),
                sub.isHidden ? @"OUI" : @"NON",
                sub.opacity,
                sub.superlayer ? NSStringFromClass(object_getClass(sub.superlayer)) : @"nil"]];
            s7tv_dumpMethods(object_getClass(sub), @"sublayer 'Animated'");
        }
    }
    [mgr log:@"🩻 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"];
}

// ── Variante B (v2) : marqueur invisible via sélecteurs de variation ─────
//
// Les "Tag characters" (U+E0000+) essayés en premier ne sont invisibles que
// derrière un emoji drapeau — testé en conditions réelles, ils s'affichaient
// comme des glyphes "manquant" visibles. Les sélecteurs de variation
// (Variation Selectors, U+FE00-U+FE0F et U+E0100-U+E01EF) sont, eux,
// invisibles PARTOUT sans condition : ils ne font que modifier l'apparence
// du caractère juste avant eux, et n'ont eux-mêmes aucun glyphe — posés
// après un caractère qui n'a aucune variante définie, ils ne s'affichent
// jamais.
//
// On encode un petit numéro court (0-65535, généré côté injection — voir
// SevenTVManager.shortIDToEmoteID) sur exactement 2 sélecteurs de variation
// (2 octets), pas l'ID complet. La correspondance courte→complète se lit
// dans le dictionnaire partagé.
//
// Contrairement aux 5 tentatives précédentes (position texte, ivar direct,
// hook d'insertion, NSLayoutManager introuvable), celle-ci ne dépend
// d'AUCUNE coopération de Twitch pour l'identification : le marqueur est
// autonome, lisible directement dans le texte final (ts.string), qu'on a
// déjà accès à chaque resize.

// Décode UN tag character (U+E0000-U+E00FF, toujours en paire de
// substitution UTF-16) à la position idx. Retourne YES et l'octet
// correspondant si trouvé, NO sinon.
static BOOL s7tv_decodeTagCharByteAt(NSString *text, NSUInteger idx, uint8_t *outByte) {
    if (idx + 1 >= text.length) return NO;
    unichar hi = [text characterAtIndex:idx];
    unichar lo = [text characterAtIndex:idx + 1];
    if (hi < 0xD800 || hi > 0xDBFF || lo < 0xDC00 || lo > 0xDFFF) return NO;
    uint32_t codepoint = 0x10000 + (((uint32_t)(hi - 0xD800)) << 10) + (lo - 0xDC00);
    if (codepoint < 0xE0000 || codepoint > 0xE00FF) return NO;
    *outByte = (uint8_t)(codepoint - 0xE0000);
    return YES;
}

// Tente de décoder un marqueur (2 tag characters = 1 short ID, 4 unités
// UTF-16 au total) commençant exactement à startIdx. Retourne YES si un ID
// complet a été décodé, NO sinon (pas une erreur — la plupart des positions
// n'ont pas de marqueur, ex: badges, texte normal).
static BOOL s7tv_decodeShortIDMarkerAt(NSString *text, NSUInteger startIdx, uint16_t *outShortID) {
    if (!text) return NO;
    uint8_t highByte, lowByte;
    if (!s7tv_decodeTagCharByteAt(text, startIdx, &highByte)) return NO;
    if (!s7tv_decodeTagCharByteAt(text, startIdx + 2, &lowByte)) return NO;
    *outShortID = (uint16_t)(((uint16_t)highByte << 8) | lowByte);
    return YES;
}

// Trouve la première "run" contiguë de tag characters (nos marqueurs) dans
// [from, limit). Retourne NSMakeRange(NSNotFound, 0) si aucune trouvée.
// Sert au hook addAttribute:/setAttributes: pour styliser ces caractères en
// invisible (couleur transparente + police quasi nulle) sans dépendre de
// notre propre tracking de position — on scanne juste ce que Twitch nous
// donne à styliser, ce qui reste correct même si les positions ont bougé.
static NSRange s7tv_tagCharRunAt(NSString *s, NSUInteger from, NSUInteger limit) {
    NSUInteger i = from;
    NSUInteger runStart = NSNotFound;
    while (i + 1 < limit) {
        uint8_t byte;
        if (s7tv_decodeTagCharByteAt(s, i, &byte)) {
            if (runStart == NSNotFound) runStart = i;
            i += 2;
            continue;
        }
        if (runStart != NSNotFound) break;
        i++;
    }
    if (runStart == NSNotFound) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(runStart, i - runStart);
}



// ────────────────────────────────────────────────────────────
// MARK: - Hijack du bouton Bits → bouton 7TV
// ────────────────────────────────────────────────────────────

@interface UIView (S7TVChatInputHook)
- (void)s7tv_didMoveToWindow;
@end

@implementation UIView (S7TVChatInputHook)

- (void)s7tv_didMoveToWindow {
    [self s7tv_didMoveToWindow]; // appel original

    NSString *selfClass = NSStringFromClass([self class]);

    // ── Hijack bouton Share → verrou orientation ──────────────────────────────
    if ([selfClass isEqualToString:@"Twitch.TheaterPlayerControlsView"] && self.window) {
        if (!objc_getAssociatedObject(self, &kS7TVShareHijacked)) {
            __weak UIView *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *controls = weakSelf;
                if (!controls || !controls.window) return;

                // Guard : uniquement dans la PictureInPictureWindow (player theater)
                if (![NSStringFromClass([controls.window class])
                        isEqualToString:@"Twitch.PictureInPictureWindow"]) return;

                // Flag posé ICI, après le guard — pas avant
                if (objc_getAssociatedObject(controls, &kS7TVShareHijacked)) return;
                objc_setAssociatedObject(controls, &kS7TVShareHijacked, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                // Trouver le bouton Share par accID
                UIButton *shareBtn = nil;
                NSMutableArray *q = [NSMutableArray arrayWithObject:controls];
                while (q.count > 0) {
                    UIView *v = q[0]; [q removeObjectAtIndex:0];
                    if ([v isKindOfClass:[UIButton class]] &&
                        [[v accessibilityIdentifier] isEqualToString:@"share_button"]) {
                        shareBtn = (UIButton *)v;
                        break;
                    }
                    [q addObjectsFromArray:v.subviews];
                }
                if (!shareBtn) {
                    [[SevenTVManager sharedManager]
                        log:@"⚠️ share_button introuvable dans TheaterPlayerControlsView"];
                    return;
                }

                // Retirer shareButtonTapped original
                NSSet *targets = [shareBtn allTargets];
                for (id tgt in [targets allObjects]) {
                    NSArray *actions = [shareBtn actionsForTarget:tgt
                                            forControlEvent:UIControlEventTouchUpInside];
                    for (NSString *action in actions) {
                        [shareBtn removeTarget:tgt action:NSSelectorFromString(action)
                              forControlEvents:UIControlEventTouchUpInside];
                        [[SevenTVManager sharedManager]
                            log:@"🔌 Share: action retirée — %@->%@",
                            NSStringFromClass([tgt class]), action];
                    }
                }

                // Icône cadenas
                UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
                    configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
                NSString *sym = s_orientationLocked ? @"lock.rotation" : @"lock.rotation.open";
                UIImage *lockIcon = [UIImage systemImageNamed:sym withConfiguration:cfg];

                for (NSNumber *st in @[@(UIControlStateNormal), @(UIControlStateHighlighted),
                                        @(UIControlStateSelected), @(UIControlStateDisabled)]) {
                    [shareBtn setImage:lockIcon forState:st.unsignedIntegerValue];
                }
                shareBtn.tintColor              = s_orientationLocked
                    ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
                    : [UIColor whiteColor];
                shareBtn.accessibilityLabel      = @"Verrouiller l'orientation";
                shareBtn.accessibilityIdentifier = @"s7tv_lock_button";

                [shareBtn addTarget:[SevenTVManager sharedManager]
                             action:@selector(s7tv_toggleOrientationLock:)
                   forControlEvents:UIControlEventTouchUpInside];

                [[SevenTVManager sharedManager]
                    log:@"✅ Bouton Share hijacké → verrou orientation"];
            });
        }
    }

    // ── Détection fermeture du stream ────────────────────────────────────────
    // Quand Twitch ferme le stream, ChatInputView quitte la fenêtre (window → nil).
    // On nettoie le picker AVANT que UIKit ne touche au responder chain.
    if ([selfClass isEqualToString:@"Twitch.ChatInputView"] && !self.window) {
        // Vérifie qu'on avait bien initialisé cette vue (associated object marqueur)
        if (objc_getAssociatedObject(self, &kS7TVTextFieldTagged)) {
            [[SevenTVManager sharedManager] cleanupPickerForStreamClose];
            // Reset le marqueur pour permettre une ré-initialisation au prochain stream
            objc_setAssociatedObject(self, &kS7TVTextFieldTagged, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    // (Ancien hack "_areEmoteAnimationsEnabled" via écriture mémoire brute
    //  supprimé : c'était la cause du crash swift_release / UITableView dealloc
    //  à la fermeture du stream — et la feature ne fonctionnait pas anyway.)

    // ── Hijack du bouton Bits → bouton 7TV ───────────────────────────────────
    if (![selfClass isEqualToString:@"Twitch.ChatInputView"]) return;
    UIView *chatInputView = self;

    if (objc_getAssociatedObject(chatInputView, &kS7TVTextFieldTagged)) return;
    objc_setAssociatedObject(chatInputView, &kS7TVTextFieldTagged, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIView *weakChatInputView = chatInputView;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *chatInputView = weakChatInputView;
        if (!chatInputView) return;
        SevenTVManager *mgr = [SevenTVManager sharedManager];

        __block UIButton *bitsBtn     = nil;
        __block UIView   *emoticonBtn = nil;
        NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithArray:chatInputView.subviews];
        while (bfs.count > 0) {
            UIView *v = bfs.firstObject; [bfs removeObjectAtIndex:0];
            [bfs addObjectsFromArray:v.subviews];
            NSString *cn = NSStringFromClass([v class]);
            if ([cn containsString:@"BitsButton"] || [cn containsString:@"bitsButton"] ||
                [[v accessibilityIdentifier] isEqualToString:@"chat_input_bits_button"]) {
                bitsBtn = (UIButton *)v;
            }
            if ([cn containsString:@"Emoticon"] || [cn containsString:@"emoticon"]) {
                emoticonBtn = v;
            }
            if (bitsBtn && emoticonBtn) break;
        }

        // CAS A : Bouton Bits trouvé → HIJACK
        if (bitsBtn && ![objc_getAssociatedObject(bitsBtn, &kS7TVBitsHijacked) boolValue]) {

            objc_setAssociatedObject(bitsBtn, &kS7TVBitsHijacked, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            NSSet *targets = [bitsBtn allTargets];
            for (id tgt in targets) {
                NSArray *actions = [bitsBtn actionsForTarget:tgt
                                            forControlEvent:UIControlEventTouchUpInside];
                for (NSString *action in actions) {
                    [bitsBtn removeTarget:tgt
                                   action:NSSelectorFromString(action)
                         forControlEvents:UIControlEventTouchUpInside];
                    [mgr log:@"🔌 Bits: action retirée — %@->%@",
                     NSStringFromClass([tgt class]), action];
                }
            }

            NSData *logoData = [[NSData alloc]
                initWithBase64EncodedString:kS7TVLogoBase64
                                   options:NSDataBase64DecodingIgnoreUnknownCharacters];
            UIImage *icon7tv = [UIImage imageWithData:logoData scale:2.0];

            if (icon7tv) {
                CGFloat targetH = emoticonBtn
                    ? MIN(emoticonBtn.bounds.size.height, emoticonBtn.bounds.size.width) * 0.75
                    : 22.0;
                if (targetH < 14) targetH = 22.0;
                CGFloat targetW = targetH * (icon7tv.size.width / MAX(icon7tv.size.height, 1.0));
                UIGraphicsBeginImageContextWithOptions(CGSizeMake(targetW, targetH), NO, [UIScreen mainScreen].scale);
                [icon7tv drawInRect:CGRectMake(0, 0, targetW, targetH)];
                UIImage *resizedIcon = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                if (resizedIcon) icon7tv = resizedIcon;

                for (NSNumber *stateNum in @[@(UIControlStateNormal),
                                             @(UIControlStateHighlighted),
                                             @(UIControlStateSelected),
                                             @(UIControlStateDisabled)]) {
                    [bitsBtn setImage:icon7tv forState:stateNum.unsignedIntegerValue];
                }
                bitsBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
                bitsBtn.tintColor = [UIColor whiteColor];
            }

            bitsBtn.accessibilityLabel = @"7TV Emotes";

            // Weak ref pour éviter le retain cycle :
            // bitsBtn (subview) retenait chatInputView (superview) → fuite mémoire.
            objc_setAssociatedObject(bitsBtn, &kS7TVTextFieldTagged,
                                     [S7TVWeakRef refWithObject:chatInputView],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            [bitsBtn addTarget:mgr
                        action:@selector(s7tv_emoteButtonTappedForButton:)
              forControlEvents:UIControlEventTouchUpInside];

            [mgr log:@"✅ Bouton Bits hijacké → 7TV (frame=%.0f,%.0f,%.0f,%.0f)",
             bitsBtn.frame.origin.x, bitsBtn.frame.origin.y,
             bitsBtn.frame.size.width, bitsBtn.frame.size.height];

        // CAS B : Pas de bouton Bits → Fallback
        } else if (!bitsBtn) {

            [mgr log:@"⚠️ ChatInputViewBitsButton introuvable — fallback injection"];

            UIView *target = emoticonBtn.superview ?: chatInputView;

            for (UIView *sub in target.subviews) {
                if (sub.tag == 0x7777) return;
            }

            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.tag = 0x7777;

            UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration
                configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
            UIImage *icon = [UIImage systemImageNamed:@"sparkles" withConfiguration:symCfg];
            UIColor *purple = [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0];

            if (icon) {
                [btn setImage:icon forState:UIControlStateNormal];
                btn.tintColor = purple;
            } else {
                [btn setTitle:@"7TV" forState:UIControlStateNormal];
                [btn setTitleColor:purple forState:UIControlStateNormal];
                btn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
            }

            CGFloat btnSize = 36.0;
            CGFloat btnX = emoticonBtn
                ? (emoticonBtn.frame.origin.x - btnSize - 4.0)
                : MAX(0, target.frame.size.width - btnSize - 4.0);
            CGFloat btnY = emoticonBtn
                ? (emoticonBtn.frame.origin.y + (emoticonBtn.frame.size.height - btnSize) / 2.0)
                : (target.frame.size.height - btnSize) / 2.0;
            if (btnX < 0) btnX = 0;

            btn.frame = CGRectMake(btnX, btnY, btnSize, btnSize);
            btn.autoresizingMask = UIViewAutoresizingFlexibleRightMargin
                                 | UIViewAutoresizingFlexibleTopMargin
                                 | UIViewAutoresizingFlexibleBottomMargin;

            // Weak ref pour éviter le retain cycle bouton → chatInputView.
            objc_setAssociatedObject(btn, &kS7TVTextFieldTagged,
                                     [S7TVWeakRef refWithObject:chatInputView],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [btn addTarget:mgr
                    action:@selector(s7tv_emoteButtonTappedForButton:)
          forControlEvents:UIControlEventTouchUpInside];

            [target addSubview:btn];
            [target bringSubviewToFront:btn];

            [mgr log:@"🎹 Bouton 7TV fallback injecté — x=%.0f y=%.0f", btnX, btnY];

        } else {
            [mgr log:@"ℹ️ Bouton Bits déjà hijacké, rien à faire"];
        }
    });
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Catégorie SevenTVManager pour le tap du bouton barre
// ────────────────────────────────────────────────────────────

@interface SevenTVManager (ChatBarButton)
- (void)s7tv_emoteButtonTappedForButton:(UIButton *)sender;
@end

@implementation SevenTVManager (ChatBarButton)

- (void)s7tv_emoteButtonTappedForButton:(UIButton *)sender {
    id assoc = objc_getAssociatedObject(sender, &kS7TVTextFieldTagged);
    UIView *chatInputView = nil;
    // Support S7TVWeakRef (nouveau) et UIView direct (legacy/compatibilité)
    if ([assoc isKindOfClass:[S7TVWeakRef class]]) {
        chatInputView = ((S7TVWeakRef *)assoc).object;
    } else {
        chatInputView = assoc;
    }
    if (!chatInputView || !chatInputView.window) return;
    [self toggleEmotePickerForChatInputView:chatInputView];
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Fix B: NSURLSessionConfiguration → protocolClasses
// ────────────────────────────────────────────────────────────

@interface NSURLSessionConfiguration (SevenTV)
- (NSArray *)s7tv_protocolClasses;
@end

@implementation NSURLSessionConfiguration (SevenTV)

- (NSArray *)s7tv_protocolClasses {
    NSArray *original = [self s7tv_protocolClasses];
    Class ourClass = [SevenTVURLProtocol class];
    if (![original containsObject:ourClass]) {
        NSMutableArray *arr = [NSMutableArray arrayWithObject:ourClass];
        if (original.count > 0) [arr addObjectsFromArray:original];
        return [arr copy];
    }
    return original;
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Hook NSURLSession (réponses API GraphQL Twitch)
// ────────────────────────────────────────────────────────────

@interface NSURLSession (SevenTV)
- (NSURLSessionDataTask *)s7tv_dataTaskWithRequest:(NSURLRequest *)request
                                 completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
- (NSURLSessionDataTask *)s7tv_dataTaskWithURL:(NSURL *)url
                             completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
@end

@implementation NSURLSession (SevenTV)

- (NSURLSessionDataTask *)s7tv_dataTaskWithRequest:(NSURLRequest *)request
                                 completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if ([request.URL.host isEqualToString:@"gql.twitch.tv"] && completionHandler) {
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (data && !error) {
                    [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:data];
                    // Détecter pub dans HLS
                    NSString *path = request.URL.path.lowercaseString;
                    if ([path hasSuffix:@".m3u8"] || [path containsString:@"m3u8"]) {
                        NSString *pl = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    }
                }
                completionHandler(data, response, error);
            };
        return [self s7tv_dataTaskWithRequest:request completionHandler:wrapped];
    }
    return [self s7tv_dataTaskWithRequest:request completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)s7tv_dataTaskWithURL:(NSURL *)url
                             completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if ([url.host isEqualToString:@"gql.twitch.tv"] && completionHandler) {
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (data && !error)
                    [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:data];
                completionHandler(data, response, error);
            };
        return [self s7tv_dataTaskWithURL:url completionHandler:wrapped];
    }
    return [self s7tv_dataTaskWithURL:url completionHandler:completionHandler];
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Fix A: Extraction room-id depuis ROOMSTATE
// ────────────────────────────────────────────────────────────

static void s7tv_handleRoomState(NSString *ircMessage) {
    NSRange roomIDRange = [ircMessage rangeOfString:@"room-id="];
    if (roomIDRange.location == NSNotFound) return;

    NSString *afterRoomID = [ircMessage substringFromIndex:roomIDRange.location + 8];
    NSMutableString *roomID = [NSMutableString string];
    for (NSUInteger i = 0; i < afterRoomID.length; i++) {
        unichar c = [afterRoomID characterAtIndex:i];
        if (c == ';' || c == ' ' || c == '\r' || c == '\n') break;
        [roomID appendFormat:@"%C", c];
    }
    if (roomID.length == 0) return;

    [[SevenTVManager sharedManager] log:@"📡 room-id extrait depuis ROOMSTATE: %@", roomID];
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    if (![roomID isEqualToString:mgr.currentChannelTwitchID]) {
        [[SevenTVManager sharedManager]
            log:@"📡 Nouveau broadcaster ID (ROOMSTATE): %@ (ancien: %@)",
            roomID, mgr.currentChannelTwitchID ?: @"aucun"];
        mgr.currentChannelTwitchID = roomID;

        if (mgr.currentChannelName.length > 0) {
            NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
            NSMutableDictionary *map =
                [([prefs dictionaryForKey:@"s7tv_channel_id_map"] ?: @{}) mutableCopy];
            map[mgr.currentChannelName.lowercaseString] = roomID;
            [prefs setObject:[map copy] forKey:@"s7tv_channel_id_map"];
            [prefs synchronize];
            [[SevenTVManager sharedManager] log:@"💾 Mapping sauvé: %@ → %@",
             mgr.currentChannelName, roomID];
        }
        [mgr loadEmotesForChannelTwitchID:roomID];

        // Notifier pour charger les badges channel-specific (abonné, bits, etc.)
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"S7TVChannelJoined"
                          object:nil
                        userInfo:@{@"channelID": roomID}];
    }
}


// ────────────────────────────────────────────────────────────
// MARK: - Hook NSURLSessionWebSocketTask (chat IRC Twitch)
// ────────────────────────────────────────────────────────────

@interface NSURLSessionWebSocketTask (SevenTV)
- (void)s7tv_receiveMessageWithCompletionHandler:
    (void (^)(NSURLSessionWebSocketMessage *, NSError *))completionHandler;
- (void)s7tv_sendMessage:(NSURLSessionWebSocketMessage *)message
       completionHandler:(void (^)(NSError *))completionHandler;
@end

@implementation NSURLSessionWebSocketTask (SevenTV)

- (void)s7tv_receiveMessageWithCompletionHandler:
    (void (^)(NSURLSessionWebSocketMessage *, NSError *))completionHandler {

    void (^wrappedHandler)(NSURLSessionWebSocketMessage *, NSError *) =
        ^(NSURLSessionWebSocketMessage *message, NSError *error) {

            if (!error && message) {
                NSString *textToProcess = nil;
                if (message.type == NSURLSessionWebSocketMessageTypeString) {
                    textToProcess = message.string;
                } else if (message.type == NSURLSessionWebSocketMessageTypeData) {
                    textToProcess = [[NSString alloc] initWithData:message.data
                                                          encoding:NSUTF8StringEncoding];
                }

                if (textToProcess) {
                    if ([textToProcess containsString:@"ROOMSTATE"]) {
                        s7tv_handleRoomState(textToProcess);
                    }

                    NSString *modified = [[SevenTVManager sharedManager]
                                          injectSevenTVEmotesIntoIRCMessage:textToProcess];

                    NSString *finalText = (modified && modified.length > 0) ? modified : textToProcess;
                    completionHandler(
                        [[NSURLSessionWebSocketMessage alloc] initWithString:finalText],
                        nil
                    );
                    return;
                }
            }
            completionHandler(message, error);
        };

    [self s7tv_receiveMessageWithCompletionHandler:wrappedHandler];
}

- (void)s7tv_sendMessage:(NSURLSessionWebSocketMessage *)message
       completionHandler:(void (^)(NSError *))completionHandler {

    if (message.type == NSURLSessionWebSocketMessageTypeString) {
        NSString *text = message.string;
        if ([text hasPrefix:@"JOIN #"]) {
            NSString *channel = [[text substringFromIndex:6]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [[SevenTVManager sharedManager] log:@"📺 Rejoint le channel: %@", channel];
            [[SevenTVManager sharedManager] loadEmotesForChannelName:channel];
        }
    }
    [self s7tv_sendMessage:message completionHandler:completionHandler];
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Tap Logger
// ────────────────────────────────────────────────────────────

BOOL s_tapLogEnabled = NO;
static NSInteger s_tapLogCount = 0;

static NSString *s7tv_viewExtra(UIView *v) {
    NSMutableString *extra = [NSMutableString string];

    if (v.accessibilityLabel.length > 0)
        [extra appendFormat:@" accLabel='%@'", v.accessibilityLabel];

    if (v.accessibilityIdentifier.length > 0)
        [extra appendFormat:@" accID='%@'", v.accessibilityIdentifier];

    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)v;
        NSArray *states = @[@(UIControlStateNormal), @(UIControlStateSelected),
                            @(UIControlStateHighlighted), @(UIControlStateDisabled)];
        NSArray *stateNames = @[@"normal", @"selected", @"highlighted", @"disabled"];
        for (NSUInteger i = 0; i < states.count; i++) {
            UIControlState st = ((NSNumber *)states[i]).unsignedIntegerValue;
            NSString *title = [btn titleForState:st];
            UIImage  *img   = [btn imageForState:st];
            if (title.length > 0)
                [extra appendFormat:@" btnTitle[%@]='%@'", stateNames[i], title];
            if (img)
                [extra appendFormat:@" btnImg[%@]=(%@)", stateNames[i], img.description];
        }
        NSSet *targets = [btn allTargets];
        for (id target in targets) {
            NSArray *actions = [btn actionsForTarget:target forControlEvent:UIControlEventTouchUpInside];
            if (actions.count > 0)
                [extra appendFormat:@" action=%@->%@",
                 NSStringFromClass([target class]), [actions componentsJoinedByString:@","]];
        }
    }

    if ([v isKindOfClass:[UITextField class]])
        [extra appendFormat:@" ph='%@'", ((UITextField *)v).placeholder ?: @""];

    if ([v isKindOfClass:[UILabel class]]) {
        NSString *txt = ((UILabel *)v).text;
        if (txt.length > 0 && txt.length <= 40)
            [extra appendFormat:@" text='%@'", txt];
    }

    return [extra copy];
}

static UIViewController *s7tv_vcForView(UIView *v) {
    UIResponder *r = v.nextResponder;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]])
            return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

@interface UIWindow (S7TVTapLogger)
- (void)s7tv_sendEvent:(UIEvent *)event;
@end

@implementation UIWindow (S7TVTapLogger)

- (void)s7tv_sendEvent:(UIEvent *)event {
    [self s7tv_sendEvent:event];

    if (!s_tapLogEnabled) return;
    if (event.type != UIEventTypeTouches) return;

    UITouch *touch = event.allTouches.anyObject;
    if (!touch || touch.phase != UITouchPhaseBegan) return;

    s_tapLogCount++;
    CGPoint pt = [touch locationInView:self];

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr log:@"👆 TAP #%ld @ (%.0f, %.0f)", (long)s_tapLogCount, pt.x, pt.y];

    UIView *keyWindow = self;
    UIResponder *currentFR = nil;
    {
        NSMutableArray<UIView *> *frQueue = [NSMutableArray arrayWithObject:keyWindow];
        while (frQueue.count > 0) {
            UIView *fv = frQueue.firstObject; [frQueue removeObjectAtIndex:0];
            if (fv.isFirstResponder) { currentFR = fv; break; }
            for (UIView *sub in fv.subviews) [frQueue addObject:sub];
        }
    }
    if (currentFR) {
        NSString *frExtra = @"";
        if ([currentFR isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)currentFR;
            frExtra = [NSString stringWithFormat:@" text='%@' selectedRange={%lu,%lu}",
                       tv.text ?: @"",
                       (unsigned long)tv.selectedRange.location,
                       (unsigned long)tv.selectedRange.length];
        }
        [mgr log:@"  FIRST_RESPONDER: %@%@",
         NSStringFromClass([currentFR class]), frExtra];
    } else {
        [mgr log:@"  FIRST_RESPONDER: (aucun)"];
    }

    UIView *hit = [self hitTest:pt withEvent:nil];
    if (!hit) {
        [mgr log:@"  HIT: (nil)"];
        return;
    }

    [mgr log:@"  HIT: %@ frame=(%.0f,%.0f,%.0f,%.0f) tag=%ld%@",
     NSStringFromClass([hit class]),
     hit.frame.origin.x, hit.frame.origin.y,
     hit.frame.size.width, hit.frame.size.height,
     (long)hit.tag,
     s7tv_viewExtra(hit)];

    UIViewController *vc = s7tv_vcForView(hit);
    if (vc) [mgr log:@"  VC: %@", NSStringFromClass([vc class])];

    UIView *v = hit.superview;
    for (int d = 1; d <= 15 && v; d++, v = v.superview) {
        [mgr log:@"  [%02d] %@ frame=(%.0f,%.0f,%.0f,%.0f)%@",
         d, NSStringFromClass([v class]),
         v.frame.origin.x, v.frame.origin.y,
         v.frame.size.width, v.frame.size.height,
         s7tv_viewExtra(v)];
    }
    [mgr log:@"  ── fin hiérarchie ──"];

    __weak UIWindow *weakWindow = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIWindow *strongWindow = weakWindow;
        if (!strongWindow) return;
        [mgr log:@"  🔍 SCAN CHAT @ (%.0f,%.0f) ──────────────", pt.x, pt.y];
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:strongWindow];
        NSInteger scanCount = 0;
        while (queue.count > 0 && scanCount < 2000) {
            UIView *sv = queue.firstObject; [queue removeObjectAtIndex:0];
            scanCount++;
            [queue addObjectsFromArray:sv.subviews];
            NSString *cn = NSStringFromClass([sv class]);
            CGRect frameInWindow = [sv convertRect:sv.bounds toView:nil];
            CGFloat dist = hypot(CGRectGetMidX(frameInWindow) - pt.x,
                                 CGRectGetMidY(frameInWindow) - pt.y);
            if (dist > 80.0) continue;

            if ([sv isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)sv;
                UIImage *img = iv.image;
                [mgr log:@"  🖼 UIImageView(%@) frame=(%.0f,%.0f,%.0f,%.0f) imgSize=(%.0f×%.0f) contentMode=%ld parent=%@",
                 cn,
                 frameInWindow.origin.x, frameInWindow.origin.y,
                 frameInWindow.size.width, frameInWindow.size.height,
                 img ? img.size.width : 0, img ? img.size.height : 0,
                 (long)iv.contentMode,
                 NSStringFromClass([sv.superview class])];
            }

            // Classes Twitch custom
            if ([cn hasPrefix:@"Twitch."] || [cn hasPrefix:@"_Tt"]) {
                NSUInteger subCount = sv.subviews.count;
                if ([cn containsString:@"Chat"] || [cn containsString:@"Cell"] ||
                    [cn containsString:@"Message"] || [cn containsString:@"Table"]) {
                    [mgr log:@"  🎯 TWITCH(%@) frame=(%.0f,%.0f,%.0f,%.0f) sub=%lu",
                     cn,
                     frameInWindow.origin.x, frameInWindow.origin.y,
                     frameInWindow.size.width, frameInWindow.size.height,
                     (unsigned long)subCount];
                }
            }
        }
        [mgr log:@"  🔍 FIN SCAN (%ld vues inspectées)", (long)scanCount];
    });
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - AccountMenuViewController — injection section 7TV
// ────────────────────────────────────────────────────────────

static NSInteger s7tv_imp_numberOfSections(id self, SEL _cmd, UITableView *tv) {
    SEL origSel = NSSelectorFromString(@"s7tv_numberOfSectionsInTableView:");
    NSInteger (*origIMP)(id, SEL, UITableView *) =
        (NSInteger (*)(id, SEL, UITableView *))
        [self methodForSelector:origSel];
    NSInteger orig = origIMP(self, origSel, tv);
    objc_setAssociatedObject(self, &kS7TVOrigSectionCount,
                             @(orig), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return orig + 1;
}

static NSInteger s7tv_origSection(NSInteger displayedSection) {
    return displayedSection - 1;
}

static NSInteger s7tv_imp_numberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    if (section == 0) return 1;
    SEL origSel = NSSelectorFromString(@"s7tv_tableView:numberOfRowsInSection:");
    NSInteger (*origIMP)(id, SEL, UITableView *, NSInteger) =
        (NSInteger (*)(id, SEL, UITableView *, NSInteger))
        [self methodForSelector:origSel];
    return origIMP(self, origSel, tv, s7tv_origSection(section));
}

static NSString *s7tv_imp_titleForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    if (section == 0) return nil;
    SEL origSel = NSSelectorFromString(@"s7tv_tableView:titleForHeaderInSection:");
    NSString *(*origIMP)(id, SEL, UITableView *, NSInteger) =
        (NSString *(*)(id, SEL, UITableView *, NSInteger))
        [self methodForSelector:origSel];
    return origIMP(self, origSel, tv, s7tv_origSection(section));
}

static UIView *s7tv_imp_viewForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    if (section != 0) {
        SEL origSel = NSSelectorFromString(@"s7tv_tableView:viewForHeaderInSection:");
        UIView *(*origIMP)(id, SEL, UITableView *, NSInteger) =
            (UIView *(*)(id, SEL, UITableView *, NSInteger))
            [self methodForSelector:origSel];
        return origIMP(self, origSel, tv, s7tv_origSection(section));
    }

    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor clearColor];

    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImageView *logoView = [[UIImageView alloc] init];
    if (logoData) logoView.image = [UIImage imageWithData:logoData scale:2.0];
    logoView.contentMode = UIViewContentModeScaleAspectFit;
    logoView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:logoView];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = @"7TV SETTINGS";
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor secondaryLabelColor];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [logoView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [logoView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [logoView.widthAnchor constraintEqualToConstant:26],
        [logoView.heightAnchor constraintEqualToConstant:19],
        [lbl.leadingAnchor constraintEqualToAnchor:logoView.trailingAnchor constant:6],
        [lbl.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
    ]];

    return container;
}

static CGFloat s7tv_imp_heightForHeader(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    if (section == 0) return 38.0;
    SEL origSel = NSSelectorFromString(@"s7tv_tableView:heightForHeaderInSection:");
    CGFloat (*origIMP)(id, SEL, UITableView *, NSInteger) =
        (CGFloat (*)(id, SEL, UITableView *, NSInteger))
        [self methodForSelector:origSel];
    return origIMP(self, origSel, tv, s7tv_origSection(section));
}

static UITableViewCell *s7tv_imp_cellForRow(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ip.section != 0) {
        NSIndexPath *origIP = [NSIndexPath indexPathForRow:ip.row
                                                 inSection:s7tv_origSection(ip.section)];
        SEL origSel = NSSelectorFromString(@"s7tv_tableView:cellForRowAtIndexPath:");
        UITableViewCell *(*origIMP)(id, SEL, UITableView *, NSIndexPath *) =
            (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))
            [self methodForSelector:origSel];
        return origIMP(self, origSel, tv, origIP);
    }

    static NSString *rID = @"S7TVSettingsCell";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:rID];
    if (!cell) {
        Class disclosureClass = NSClassFromString(@"Twitch.SettingsDisclosureCell")
                              ?: NSClassFromString(@"_TtC6Twitch22SettingsDisclosureCell");
        if (disclosureClass) {
            cell = [[disclosureClass alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:rID];
        }
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:rID];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    cell.textLabel.text = @"7TV Settings";
    cell.textLabel.numberOfLines = 0;

    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (logoData) {
        UIImage *logo = [UIImage imageWithData:logoData scale:2.0];
        if (logo) cell.imageView.image = logo;
    }

    return cell;
}

static void s7tv_imp_didSelect(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    if (ip.section != 0) {
        NSIndexPath *origIP = [NSIndexPath indexPathForRow:ip.row
                                                 inSection:s7tv_origSection(ip.section)];
        SEL origSel = NSSelectorFromString(@"s7tv_tableView:didSelectRowAtIndexPath:");
        void (*origIMP)(id, SEL, UITableView *, NSIndexPath *) =
            (void (*)(id, SEL, UITableView *, NSIndexPath *))
            [self methodForSelector:origSel];
        origIMP(self, origSel, tv, origIP);
        return;
    }

    [tv deselectRowAtIndexPath:ip animated:YES];
    SevenTVSettingsController *vc = [[SevenTVSettingsController alloc] init];
    UINavigationController *nav = ((UIViewController *)self).navigationController;
    [nav pushViewController:vc animated:YES];
    [[SevenTVManager sharedManager] log:@"✅ 7TV Settings ouvert depuis les paramètres Twitch"];
}

static void s7tv_swizzle_account_menu(void) {
    Class target = NSClassFromString(@"_TtC6Twitch25AccountMenuViewController");
    if (!target) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ _TtC6Twitch25AccountMenuViewController introuvable — swizzle ignoré"];
        return;
    }

    void (^swizzleWithIMP)(SEL, SEL, IMP, const char *) =
        ^(SEL origSel, SEL newSel, IMP newIMP, const char *types) {
            Method origMethod = class_getInstanceMethod(target, origSel);
            if (!origMethod) return;
            // CRITICAL FIX: if the method is only *inherited* (not defined directly on
            // target), class_getInstanceMethod returns the superclass's Method object.
            // Calling method_exchangeImplementations on it would modify the superclass,
            // affecting ALL subclasses including SearchTopResultsViewController → crash.
            // Solution: add the original IMP directly on target first so the exchange
            // only touches target's own method table.
            class_addMethod(target, origSel,
                            method_getImplementation(origMethod),
                            method_getTypeEncoding(origMethod));
            // Add our replacement under the s7tv_ selector
            class_addMethod(target, newSel, newIMP, types);
            // Re-fetch: origMethod now points to target's own copy (not superclass)
            Method orig = class_getInstanceMethod(target, origSel);
            Method repl = class_getInstanceMethod(target, newSel);
            if (orig && repl) method_exchangeImplementations(orig, repl);
        };

    swizzleWithIMP(@selector(numberOfSectionsInTableView:),
        NSSelectorFromString(@"s7tv_numberOfSectionsInTableView:"),
        (IMP)s7tv_imp_numberOfSections, "q@:@");
    swizzleWithIMP(@selector(tableView:numberOfRowsInSection:),
        NSSelectorFromString(@"s7tv_tableView:numberOfRowsInSection:"),
        (IMP)s7tv_imp_numberOfRows, "q@:@q");
    swizzleWithIMP(@selector(tableView:titleForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:titleForHeaderInSection:"),
        (IMP)s7tv_imp_titleForHeader, "@@:@q");
    swizzleWithIMP(@selector(tableView:viewForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:viewForHeaderInSection:"),
        (IMP)s7tv_imp_viewForHeader, "@@:@q");
    swizzleWithIMP(@selector(tableView:heightForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:heightForHeaderInSection:"),
        (IMP)s7tv_imp_heightForHeader, "d@:@q");
    swizzleWithIMP(@selector(tableView:cellForRowAtIndexPath:),
        NSSelectorFromString(@"s7tv_tableView:cellForRowAtIndexPath:"),
        (IMP)s7tv_imp_cellForRow, "@@:@@");
    swizzleWithIMP(@selector(tableView:didSelectRowAtIndexPath:),
        NSSelectorFromString(@"s7tv_tableView:didSelectRowAtIndexPath:"),
        (IMP)s7tv_imp_didSelect, "v@:@@");

    [[SevenTVManager sharedManager]
        log:@"✅ AccountMenuViewController swizzlé — section 7TV Settings injectée"];
}


// ────────────────────────────────────────────────────────────
// MARK: - Swizzle NSURLSessionConfiguration.protocolClasses
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle_protocol_classes(void) {
    NSURLSessionConfiguration *probe = [NSURLSessionConfiguration defaultSessionConfiguration];
    Class configClass = object_getClass(probe);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSessionConfiguration classe: %@",
     NSStringFromClass(configClass)];
    s7tv_swizzle(configClass,
                 [NSURLSessionConfiguration class],
                 @selector(protocolClasses),
                 @selector(s7tv_protocolClasses));
}


// ────────────────────────────────────────────────────────────
// MARK: - Swizzle NSURLSession (classe concrète via sonde)
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle_session(void) {
    SEL selRequest  = @selector(dataTaskWithRequest:completionHandler:);
    SEL selURL      = @selector(dataTaskWithURL:completionHandler:);
    SEL swizRequest = @selector(s7tv_dataTaskWithRequest:completionHandler:);
    SEL swizURL     = @selector(s7tv_dataTaskWithURL:completionHandler:);

    NSURLSession *probeStd = [NSURLSession sessionWithConfiguration:
                              [NSURLSessionConfiguration defaultSessionConfiguration]];
    Class classStd = object_getClass(probeStd);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSession standard: %@",
     NSStringFromClass(classStd)];
    s7tv_swizzle(classStd, [NSURLSession class], selRequest, swizRequest);
    s7tv_swizzle(classStd, [NSURLSession class], selURL, swizURL);

    Class classShared = object_getClass([NSURLSession sharedSession]);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSession shared: %@",
     NSStringFromClass(classShared)];
    if (classShared != classStd) {
        s7tv_swizzle(classShared, [NSURLSession class], selRequest, swizRequest);
        s7tv_swizzle(classShared, [NSURLSession class], selURL, swizURL);
    } else {
        [[SevenTVManager sharedManager] log:@"ℹ️  sharedSession même classe que standard"];
    }
}


// ────────────────────────────────────────────────────────────
// MARK: - Swizzle NSURLSessionWebSocketTask (classe concrète)
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle_websocket(void) {
    Class wsAbstractClass = NSClassFromString(@"NSURLSessionWebSocketTask");
    if (!wsAbstractClass) {
        [[SevenTVManager sharedManager] log:@"⚠️  NSURLSessionWebSocketTask introuvable"];
        return;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *probeSession = [NSURLSession sessionWithConfiguration:cfg];
    NSURL *probeURL = [NSURL URLWithString:@"wss://irc-ws.chat.twitch.tv/irc"];
    NSURLSessionWebSocketTask *probeTask = [probeSession webSocketTaskWithURL:probeURL];
    Class realWSClass = object_getClass(probeTask);
    [probeTask cancel];

    [[SevenTVManager sharedManager] log:@"🔍 WebSocketTask classe concrète: %@",
     NSStringFromClass(realWSClass)];

    s7tv_swizzle(realWSClass, wsAbstractClass,
                 @selector(receiveMessageWithCompletionHandler:),
                 @selector(s7tv_receiveMessageWithCompletionHandler:));
    s7tv_swizzle(realWSClass, wsAbstractClass,
                 @selector(sendMessage:completionHandler:),
                 @selector(s7tv_sendMessage:completionHandler:));
}


// ────────────────────────────────────────────────────────────
// MARK: - Hook TwitchKit.NetworkImageRequester (lecture seule)
// Intercepte imageAtURL: et animatedImageAtURL: pour voir lequel
// est appelé pour nos URLs cdn.7tv.app — et avec quels args.
// ────────────────────────────────────────────────────────────

static void s7tv_hook_network_image_requester(void) {
    // Extrait l'emoteID depuis une URL CDN du type
    // https://cdn.7tv.app/emote/<emoteID>/2x.webp (ou tout autre format
    // contenant "/emote/<id>/").
    NSString *(^extractEmoteID)(NSString *) = ^NSString *(NSString *urlStr) {
        NSRange marker = [urlStr rangeOfString:@"/emote/"];
        if (marker.location == NSNotFound) return nil;
        NSString *afterMarker = [urlStr substringFromIndex:marker.location + marker.length];
        NSRange nextSlash = [afterMarker rangeOfString:@"/"];
        if (nextSlash.location == NSNotFound) return afterMarker;
        return [afterMarker substringToIndex:nextSlash.location];
    };

    Class nic = NSClassFromString(@"TwitchKit.NetworkImageRequester");
    if (!nic) {
        [[SevenTVManager sharedManager] log:@"⚠️ NetworkImageRequester introuvable"];
        return;
    }

    SevenTVManager *mgr = [SevenTVManager sharedManager];

    // Marqueur de filtre — grep "🟢7TV" dans les logs pour savoir d'un coup
    // si NetworkImageRequester est emprunté pour nos URLs cdn.7tv.app.
    // Absence totale de 🟢7TV après affichage d'une emote 7TV dans le chat
    // = ce pipeline n'est PAS utilisé pour ce chemin → piste à abandonner.
    static NSString *const kS7TVMarker = @"cdn.7tv.app";

    // ── variante courte : imageAtURL:withScale:persistingFor: ──
    SEL selImg1 = NSSelectorFromString(@"imageAtURL:withScale:persistingFor:");
    Method mImg1 = class_getInstanceMethod(nic, selImg1);
    if (mImg1) {
        IMP orig = method_getImplementation(mImg1);
        method_setImplementation(mImg1, imp_implementationWithBlock(
            ^id(id self_, NSURL *url, CGFloat scale, id persist) {
                NSString *urlStr = url.absoluteString ?: @"";
                BOOL isS7TV = [urlStr containsString:kS7TVMarker];
                if (isS7TV) {
                    [mgr log:@"🟢7TV 🖼A %@  scale=%.1f", urlStr, scale];
                } else {
                    [mgr log:@"🖼A %@  scale=%.1f", urlStr, scale];
                }
                id result = ((id(*)(id,SEL,NSURL*,CGFloat,id))orig)(self_, selImg1, url, scale, persist);
                if (isS7TV && result) {
                    NSString *emoteID = extractEmoteID(urlStr);
                    NSNumber *ratio = emoteID ? mgr.emoteRatios[emoteID] : nil;
                    if (ratio) {
                        objc_setAssociatedObject(result, &kS7TVEmoteRatioKey, ratio, OBJC_ASSOCIATION_RETAIN);
                    }
                }
                return result;
            }));
        [mgr log:@"✅ Hook imageAtURL:withScale:persistingFor: OK"];
    }

    // ── variante longue : imageAtURL:withScale:persistingFor:storeInMemoryCache:userInitiated: ──
    SEL selImg2 = NSSelectorFromString(@"imageAtURL:withScale:persistingFor:storeInMemoryCache:userInitiated:");
    Method mImg2 = class_getInstanceMethod(nic, selImg2);
    if (mImg2) {
        IMP orig = method_getImplementation(mImg2);
        method_setImplementation(mImg2, imp_implementationWithBlock(
            ^id(id self_, NSURL *url, CGFloat scale, id persist, BOOL mem, BOOL user) {
                NSString *urlStr = url.absoluteString ?: @"";
                BOOL isS7TV = [urlStr containsString:kS7TVMarker];
                if (isS7TV) {
                    [mgr log:@"🟢7TV 🖼B %@  scale=%.1f mem=%d user=%d", urlStr, scale, mem, user];
                } else {
                    [mgr log:@"🖼B %@  scale=%.1f mem=%d user=%d", urlStr, scale, mem, user];
                }
                id result = ((id(*)(id,SEL,NSURL*,CGFloat,id,BOOL,BOOL))orig)(self_, selImg2, url, scale, persist, mem, user);
                if (isS7TV && result) {
                    NSString *emoteID = extractEmoteID(urlStr);
                    NSNumber *ratio = emoteID ? mgr.emoteRatios[emoteID] : nil;
                    if (ratio) {
                        objc_setAssociatedObject(result, &kS7TVEmoteRatioKey, ratio, OBJC_ASSOCIATION_RETAIN);
                    }
                }
                return result;
            }));
        [mgr log:@"✅ Hook imageAtURL:...:storeInMemoryCache:userInitiated: OK"];
    }

    // ── Sélecteur startAnimating partagé ──
    SEL startSel = NSSelectorFromString(@"startAnimating");

    // ── variante courte : animatedImageAtURL:withStaticScale:persistingFor: ──
    SEL selAnim1 = NSSelectorFromString(@"animatedImageAtURL:withStaticScale:persistingFor:");
    Method mAnim1 = class_getInstanceMethod(nic, selAnim1);
    if (mAnim1) {
        IMP orig = method_getImplementation(mAnim1);
        method_setImplementation(mAnim1, imp_implementationWithBlock(
            ^id(id self_, NSURL *url, CGFloat scale, id persist) {
                NSString *urlStr = url.absoluteString ?: @"";
                BOOL isS7TV = [urlStr containsString:kS7TVMarker];
                id result = ((id(*)(id,SEL,NSURL*,CGFloat,id))orig)(self_, selAnim1, url, scale, persist);
                BOOL responds = result && [result respondsToSelector:startSel];
                if (isS7TV) {
                    [mgr log:@"🟢7TV animatedImageAtURL:withStaticScale:persistingFor: → %@  result=%@ respondsStartAnimating=%@",
                        urlStr, result ? NSStringFromClass(object_getClass(result)) : @"nil",
                        responds ? @"OUI" : @"NON"];
                    if (result) {
                        NSString *emoteID = extractEmoteID(urlStr);
                        NSNumber *ratio = emoteID ? mgr.emoteRatios[emoteID] : nil;
                        if (ratio) {
                            objc_setAssociatedObject(result, &kS7TVEmoteRatioKey, ratio, OBJC_ASSOCIATION_RETAIN);
                        }
                    }
                }
                // Appeler startAnimating sur le résultat si disponible
                if (responds) {
                    ((void(*)(id,SEL))objc_msgSend)(result, startSel);
                }
                return result;
            }));
        [mgr log:@"✅ Hook animatedImageAtURL:withStaticScale:persistingFor: OK"];
    }

    // ── variante longue : animatedImageAtURL:withStaticScale:persistingFor:userInitiated: ──
    SEL selAnim2 = NSSelectorFromString(@"animatedImageAtURL:withStaticScale:persistingFor:userInitiated:");
    Method mAnim2 = class_getInstanceMethod(nic, selAnim2);
    if (mAnim2) {
        IMP orig = method_getImplementation(mAnim2);
        method_setImplementation(mAnim2, imp_implementationWithBlock(
            ^id(id self_, NSURL *url, CGFloat scale, id persist, BOOL user) {
                NSString *urlStr = url.absoluteString ?: @"";
                BOOL isS7TV = [urlStr containsString:kS7TVMarker];
                id result = ((id(*)(id,SEL,NSURL*,CGFloat,id,BOOL))orig)(self_, selAnim2, url, scale, persist, user);
                BOOL responds = result && [result respondsToSelector:startSel];
                if (isS7TV) {
                    [mgr log:@"🟢7TV animatedImageAtURL:...:userInitiated: → %@  result=%@ respondsStartAnimating=%@",
                        urlStr, result ? NSStringFromClass(object_getClass(result)) : @"nil",
                        responds ? @"OUI" : @"NON"];
                    if (result) {
                        NSString *emoteID = extractEmoteID(urlStr);
                        NSNumber *ratio = emoteID ? mgr.emoteRatios[emoteID] : nil;
                        if (ratio) {
                            objc_setAssociatedObject(result, &kS7TVEmoteRatioKey, ratio, OBJC_ASSOCIATION_RETAIN);
                        }
                    }
                }
                // Appeler startAnimating sur le résultat si disponible
                if (responds) {
                    ((void(*)(id,SEL))objc_msgSend)(result, startSel);
                }
                return result;
            }));
        [mgr log:@"✅ Hook animatedImageAtURL:...:userInitiated: OK"];
    }
}


// ────────────────────────────────────────────────────────────
// MARK: - Verrou d'orientation (bouton Share hijacké)
// Approche : requestGeometryUpdate (iOS 16+) pour forcer l'orientation
// de la scène au niveau système — c'est la seule API qui contrôle
// réellement la rotation visuelle sur les apps SwiftUI modernes.
// Combiné avec shouldAutorotate=NO pour bloquer UIKit en parallèle.
// ────────────────────────────────────────────────────────────

// ── Orientation verrouillée capturée au moment du lock ───────────────────────
static UIInterfaceOrientation s_lockedOrientation = UIInterfaceOrientationUnknown;

// ── Observer rotation physique ───────────────────────────────────────────────
static id s_orientationObserver = nil;

// ── Force la géométrie de toutes les scènes actives ─────────────────────────
static void s7tv_forceSceneOrientation(UIInterfaceOrientationMask mask) {
    // iOS 16+ : UIWindowScene requestGeometryUpdate:errorHandler:
    // Appelé via objc_msgSend pour éviter les erreurs de header manquant dans le SDK Theos
    SEL reqSel   = NSSelectorFromString(@"requestGeometryUpdate:errorHandler:");
    Class prefsCls = NSClassFromString(@"UIWindowSceneGeometryPreferencesIOS");

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;

        if (prefsCls && [ws respondsToSelector:reqSel]) {
            id prefs = [[prefsCls alloc] initWithInterfaceOrientations:mask];
            ((void(*)(id, SEL, id, id))objc_msgSend)(ws, reqSel, prefs, nil);
        } else {
            // Fallback iOS < 16 : setStatusBarOrientation:animated: (déprécié)
            UIInterfaceOrientation target = UIInterfaceOrientationPortrait;
            if (mask == UIInterfaceOrientationMaskLandscapeLeft)               target = UIInterfaceOrientationLandscapeLeft;
            else if (mask == UIInterfaceOrientationMaskLandscapeRight)         target = UIInterfaceOrientationLandscapeRight;
            else if (mask == UIInterfaceOrientationMaskPortraitUpsideDown)     target = UIInterfaceOrientationPortraitUpsideDown;
            SEL fbSel = NSSelectorFromString(@"setStatusBarOrientation:animated:");
            ((void(*)(id, SEL, UIInterfaceOrientation, BOOL))objc_msgSend)(
                [UIApplication sharedApplication], fbSel, target, NO);
        }
    }
}

// ── Démarre l'observer qui journalise les rotations physiques ────────────────
// Note : le blocage visuel est assuré par supportedInterfaceOrientationsForWindow:
// On n'appelle plus requestGeometryUpdate ici — c'était lui qui causait le flash
// "rotate puis snap back" en jouant une animation de retour inutile.
static void s7tv_startOrientationObserver(void) {
    if (s_orientationObserver) return;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    s_orientationObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIDeviceOrientationDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) {
        if (!s_orientationLocked) return;
        [[SevenTVManager sharedManager] log:@"🔒 Rotation physique bloquée (verrou actif)"];
    }];
}

static void s7tv_stopOrientationObserver(void) {
    if (!s_orientationObserver) return;
    [[NSNotificationCenter defaultCenter] removeObserver:s_orientationObserver];
    s_orientationObserver = nil;
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

// ── Toast ─────────────────────────────────────────────────────────────────────
// Fenêtre dédiée au toast — niveau UIWindowLevelAlert pour passer au-dessus
// du player Twitch qui tourne sur une fenêtre de niveau supérieur à Normal.
static UIWindow *s_toastWindow = nil;

static void s7tv_showOrientationToast(BOOL locked) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Trouver la UIWindowScene active
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        if (!activeScene) return;

        // Créer une fenêtre dédiée au niveau Alert — au-dessus du player Twitch
        UIWindow *toastWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
        toastWindow.windowLevel = UIWindowLevelAlert;
        toastWindow.backgroundColor = [UIColor clearColor];
        toastWindow.userInteractionEnabled = NO;
        // Rootvc minimal pour pouvoir addSubview
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        toastWindow.rootViewController = rootVC;
        toastWindow.hidden = NO;
        s_toastWindow = toastWindow; // retain

        UIView *container = toastWindow.rootViewController.view;
        CGFloat winW = toastWindow.bounds.size.width;
        CGFloat winH = toastWindow.bounds.size.height;

        NSString *symbol = locked ? @"lock.rotation"      : @"lock.rotation.open";
        NSString *label  = locked ? @"Verrouillé" : @"Déverrouillé";

        UIView *toast = [[UIView alloc] init];
        toast.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.62];
        toast.layer.cornerRadius = 14;
        toast.layer.masksToBounds = YES;
        toast.alpha = 0;
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:toast];

        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
        UIImage *icon = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
        iconView.tintColor   = locked
            ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
            : [UIColor colorWithRed:0.6  green:0.6  blue:0.65 alpha:1.0];
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [toast addSubview:iconView];

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text      = label;
        lbl.font      = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        lbl.textColor = [UIColor whiteColor];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [toast addSubview:lbl];

        [NSLayoutConstraint activateConstraints:@[
            [iconView.leadingAnchor  constraintEqualToAnchor:toast.leadingAnchor  constant:12],
            [iconView.centerYAnchor  constraintEqualToAnchor:toast.centerYAnchor],
            [iconView.widthAnchor    constraintEqualToConstant:18],
            [iconView.heightAnchor   constraintEqualToConstant:18],
            [lbl.leadingAnchor       constraintEqualToAnchor:iconView.trailingAnchor constant:8],
            [lbl.trailingAnchor      constraintEqualToAnchor:toast.trailingAnchor    constant:-12],
            [lbl.centerYAnchor       constraintEqualToAnchor:toast.centerYAnchor],
            [toast.heightAnchor      constraintEqualToConstant:38],
            [toast.centerXAnchor     constraintEqualToAnchor:container.centerXAnchor],
            [toast.bottomAnchor      constraintEqualToAnchor:container.bottomAnchor constant:-(winH * 0.12)],
        ]];

        [container layoutIfNeeded];

        [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 1.0; } completion:^(BOOL f) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; }
                                 completion:^(BOOL ff) {
                    [toast removeFromSuperview];
                    s_toastWindow.hidden = YES;
                    s_toastWindow = nil; // libérer
                }];
            });
        }];
    });
}

// ── Hook principal : UIApplication.supportedInterfaceOrientationsForWindow: ──
// C'est le check système qui prime sur toutes les overrides Twitch dans les VCs.
@interface UIApplication (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientationsForWindow:(UIWindow *)window;
@end
@implementation UIApplication (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    if (s_orientationLocked) return s_lockedOrientationMask;
    return [self s7tv_supportedInterfaceOrientationsForWindow:window];
}
@end

// ── Garde UIViewController au cas où (certains chemins UIKit passent par là) ──
@interface UIViewController (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientations;
@end
@implementation UIViewController (S7TVOrientationLock)
- (UIInterfaceOrientationMask)s7tv_supportedInterfaceOrientations {
    if (s_orientationLocked) return s_lockedOrientationMask;
    return [self s7tv_supportedInterfaceOrientations];
}
@end

@interface UIViewController (S7TVAutorotate)
- (BOOL)s7tv_shouldAutorotate;
@end
@implementation UIViewController (S7TVAutorotate)
- (BOOL)s7tv_shouldAutorotate {
    if (s_orientationLocked) return NO;
    return [self s7tv_shouldAutorotate];
}
@end

// ── Action toggle ─────────────────────────────────────────────────────────────
@interface SevenTVManager (OrientationLock)
- (void)s7tv_toggleOrientationLock:(UIButton *)sender;
@end
@implementation SevenTVManager (OrientationLock)

static void s7tv_install_orientation_swizzles(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s7tv_swizzle([UIApplication class],
                     [UIApplication class],
                     @selector(supportedInterfaceOrientationsForWindow:),
                     NSSelectorFromString(@"s7tv_supportedInterfaceOrientationsForWindow:"));
        s7tv_swizzle([UIViewController class],
                     [UIViewController class],
                     @selector(supportedInterfaceOrientations),
                     @selector(s7tv_supportedInterfaceOrientations));
        s7tv_swizzle([UIViewController class],
                     [UIViewController class],
                     @selector(shouldAutorotate),
                     @selector(s7tv_shouldAutorotate));
        [[SevenTVManager sharedManager] log:@"✅ Swizzles verrou orientation installés (premier lock)"];
    });
}

- (void)s7tv_toggleOrientationLock:(UIButton *)sender {
    s_orientationLocked = !s_orientationLocked;

    if (s_orientationLocked) {
        // Installer les swizzles seulement maintenant, pas au lancement
        s7tv_install_orientation_swizzles();

        // Capturer l'orientation courante de la scène
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        UIInterfaceOrientation current = activeScene
            ? activeScene.interfaceOrientation
            : UIInterfaceOrientationPortrait;

        s_lockedOrientation = current;
        switch (current) {
            case UIInterfaceOrientationLandscapeLeft:
                s_lockedOrientationMask = UIInterfaceOrientationMaskLandscapeLeft;  break;
            case UIInterfaceOrientationLandscapeRight:
                s_lockedOrientationMask = UIInterfaceOrientationMaskLandscapeRight; break;
            case UIInterfaceOrientationPortraitUpsideDown:
                s_lockedOrientationMask = UIInterfaceOrientationMaskPortraitUpsideDown; break;
            default:
                s_lockedOrientationMask = UIInterfaceOrientationMaskPortrait; break;
        }

        // Le mask est posé — supportedInterfaceOrientationsForWindow: bloque dès maintenant.
        // On n'appelle PAS requestGeometryUpdate ici : l'utilisateur est déjà dans la bonne
        // orientation, un appel inutile ouvre une fenêtre où la première rotation physique
        // peut passer avant que le cycle de géométrie soit stabilisé.
        s7tv_startOrientationObserver();
        [self log:@"🔒 Orientation verrouillée (orientation=%ld)", (long)current];

    } else {
        s_lockedOrientationMask = UIInterfaceOrientationMaskAll;
        s_lockedOrientation     = UIInterfaceOrientationUnknown;
        s7tv_stopOrientationObserver();
        // Libérer toutes les orientations → iOS reprend la main
        s7tv_forceSceneOrientation(UIInterfaceOrientationMaskAll);
        [UIViewController attemptRotationToDeviceOrientation];
        [self log:@"🔓 Orientation déverrouillée"];
    }

    // Mettre à jour l'icône du bouton
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
    NSString *sym = s_orientationLocked ? @"lock.rotation" : @"lock.rotation.open";
    UIImage *icon = [UIImage systemImageNamed:sym withConfiguration:cfg];
    UIColor *tint = s_orientationLocked
        ? [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
        : [UIColor whiteColor];

    for (NSNumber *st in @[@(UIControlStateNormal), @(UIControlStateHighlighted),
                            @(UIControlStateSelected), @(UIControlStateDisabled)]) {
        [sender setImage:icon forState:st.unsignedIntegerValue];
    }
    sender.tintColor = tint;

    s7tv_showOrientationToast(s_orientationLocked);
}

@end

static void s7tv_swizzle_orientation_lock(void) {
    // Swizzles installés à la demande au premier lock, pas au lancement.
}


// ────────────────────────────────────────────────────────────
// MARK: - DEBUG — Dump complet du système de layout des attachments
//
// Objectif : identifier QUELLE méthode est réellement responsable du
// dimensionnement des NSTextAttachment (emotes) dans le chat Twitch,
// puisque sizeOfImageAttachmentAtCharacterIndex: n'est jamais appelée.
//
// Stratégie :
//   1. Dump la liste complète des méthodes (avec type encoding) des
//      classes Twitch impliquées dans le rendu du texte du chat.
//   2. Hook les 2 méthodes "candidates historiques" connues du projet :
//      - NSTextAttachment.attachmentBoundsForTextContainer:proposedLineFragment:glyphPosition:characterIndex:
//      - NSLayoutManager.setAttachmentSize:forGlyphRange:
//   3. Hook addAttribute:value:range: / setAttributes:range: sur
//      NSMutableAttributedString pour voir, en temps réel, QUELLE classe
//      d'objet est utilisée comme NSTextAttachment par Twitch (sa vraie
//      classe peut être une sous-classe custom, pas NSTextAttachment nu).
// ────────────────────────────────────────────────────────────

static void s7tv_dbg_dumpMethodsForClass(Class cls, NSString *label) {
    if (!cls) {
        [[SevenTVManager sharedManager] log:@"🐛 [DBG-DUMP] %@ → classe introuvable (nil)", label];
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    [[SevenTVManager sharedManager] log:@"🐛 [DBG-DUMP] ━━━ %@ (%@) — %u méthodes ━━━",
        label, NSStringFromClass(cls), count];
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        const char *encoding = method_getTypeEncoding(methods[i]);
        [[SevenTVManager sharedManager] log:@"🐛 [DBG-DUMP]   - %@  [%s]",
            NSStringFromSelector(sel), encoding ?: "?"];
    }
    if (methods) free(methods);

    // Remonte aussi la superclasse directe (souvent là où vit le vrai layout)
    Class superCls = class_getSuperclass(cls);
    if (superCls && superCls != [NSObject class]) {
        unsigned int superCount = 0;
        Method *superMethods = class_copyMethodList(superCls, &superCount);
        [[SevenTVManager sharedManager] log:@"🐛 [DBG-DUMP] ━━━ %@ → superclasse %@ — %u méthodes ━━━",
            label, NSStringFromClass(superCls), superCount];
        for (unsigned int i = 0; i < superCount; i++) {
            SEL sel = method_getName(superMethods[i]);
            const char *encoding = method_getTypeEncoding(superMethods[i]);
            [[SevenTVManager sharedManager] log:@"🐛 [DBG-DUMP]   - %@  [%s]",
                NSStringFromSelector(sel), encoding ?: "?"];
        }
        if (superMethods) free(superMethods);
    }
}

// ────────────────────────────────────────────────────────────
// s7tv_ratioFromLayerContents
//
// Source de vérité pour les hooks au niveau CALayer (displayLayer:,
// setFrame:) : lit le ratio directement depuis les PIXELS réels de
// l'image affichée (layer.contents, un CGImageRef), plutôt que depuis
// un frame/bounds que Twitch vient de proposer — ce dernier reflète
// souvent une taille par défaut/pas encore réelle (d'où le bug carré
// observé sur BOUNDS/ATTSIZE avant leur fix).
// Cherche aussi dans les sublayers (profondeur 1) si le layer passé
// est un simple conteneur sans contents propre.
// Retourne 0 si aucune donnée fiable trouvée (jamais de fallback 1.0
// inventé ici — l'appelant doit alors ignorer le resize).
// ────────────────────────────────────────────────────────────
static CGFloat s7tv_ratioFromLayerContents(CALayer *layer) {
    if (!layer) return 0;

    CGImageRef img = (__bridge CGImageRef)layer.contents;
    if (img && CFGetTypeID(img) == CGImageGetTypeID()) {
        size_t w = CGImageGetWidth(img);
        size_t h = CGImageGetHeight(img);
        if (w > 0 && h > 0) return (CGFloat)w / (CGFloat)h;
    }

    for (CALayer *sub in layer.sublayers) {
        CGImageRef subImg = (__bridge CGImageRef)sub.contents;
        if (subImg && CFGetTypeID(subImg) == CGImageGetTypeID()) {
            size_t w = CGImageGetWidth(subImg);
            size_t h = CGImageGetHeight(subImg);
            if (w > 0 && h > 0) return (CGFloat)w / (CGFloat)h;
        }
    }

    return 0;
}

static void s7tv_hook_displayLayer(void) {
    // Hook displayLayer: sur Twitch.AnimatedImageAttachmentLayer.
    // Installé tôt (à t=3s) pour être actif dès le premier message avec emote.
    // Fire quand l'image est prête → Twitch a fini tous ses setFrame: → bon timing
    // pour corriger le frame du superlayer (ImageAttachmentLayer) sans conflit.
    Class animLayerCls = NSClassFromString(@"Twitch.AnimatedImageAttachmentLayer");
    if (!animLayerCls) {
        [[SevenTVManager sharedManager] log:@"⚠️ [displayLayer hook] AnimatedImageAttachmentLayer introuvable à t=3s — sera installé lazily"];
        return;
    }
    SEL displaySel = NSSelectorFromString(@"displayLayer:");
    Method dm = class_getInstanceMethod(animLayerCls, displaySel);
    if (!dm) {
        [[SevenTVManager sharedManager] log:@"⚠️ [displayLayer hook] méthode displayLayer: introuvable"];
        return;
    }
    IMP origIMP = method_getImplementation(dm);
    SEL startSel = NSSelectorFromString(@"startAnimating");
    method_setImplementation(dm, imp_implementationWithBlock(^(id selfObj, id layerArg) {
        @try { ((void(*)(id,SEL,id))origIMP)(selfObj, displaySel, layerArg); } @catch(...) {}
        @try {
            // startAnimating pour les GIF animés
            if ([selfObj respondsToSelector:startSel]) {
                ((void(*)(id,SEL))objc_msgSend)(selfObj, startSel);
            }
            // Resize du superlayer (ImageAttachmentLayer) si pas encore fait
            CALayer *outer = [(CALayer *)selfObj superlayer];
            if (outer) {
                CGRect outerFrame = outer.frame;
                CGFloat oh = outerFrame.size.height;
                if (oh > 0 && oh <= 22.0) {
                    CGFloat targetSize = [[SevenTVManager sharedManager] targetEmoteSize];
                    // Source de vérité : pixels réels de selfObj (le layer animé
                    // qui affiche le GIF/WebP décodé), pas outerFrame — outerFrame
                    // est le container encore à sa taille par défaut à cet instant.
                    CGFloat ratio = s7tv_ratioFromLayerContents((CALayer *)selfObj);
                    if (ratio <= 0) ratio = s7tv_ratioFromLayerContents(outer);
                    if (ratio > 0) {
                        CGFloat newW = targetSize * ratio;
                        CGRect corrected = CGRectMake(
                            outerFrame.origin.x,
                            outerFrame.origin.y + (oh - targetSize) / 2.0,
                            newW, targetSize);
                        [CATransaction begin];
                        [CATransaction setDisableActions:YES];
                        outer.frame = corrected;
                        [CATransaction commit];
                    }
                    // ratio <= 0 → pas de donnée pixel fiable, on ne touche pas
                    // (jamais de fallback carré inventé)
                }
            }
        } @catch(...) {}
    }));
    [[SevenTVManager sharedManager] log:@"✅ Hook displayLayer: sur AnimatedImageAttachmentLayer OK (installé tôt)"];
}

static void s7tv_dbg_hookAttachmentBounds(void) {
    // - (CGRect)attachmentBoundsForTextContainer:(NSTextContainer*)tc
    //                       proposedLineFragment:(CGRect)rect
    //                              glyphPosition:(CGPoint)pos
    //                            characterIndex:(NSUInteger)idx
    //
    // Stratégie v3 : on n'a plus besoin du tag kS7TVEmoteRatioKey.
    // Les logs ont confirmé que image=UIImage est DÉJÀ présente (Twitch charge
    // les images via un pipeline interne qui ne passe pas par imageWithData:).
    // On utilise directement image.size pour calculer le ratio — ça couvre
    // les emotes 7TV ET les emotes Twitch natives (agrandissement uniforme).
    // Garde : seulement si la taille par défaut retournée est <= 22pt
    // (= emotes standard — exclut badges et éléments déjà correctement taillés).
    Class cls = [NSTextAttachment class];
    SEL sel = @selector(attachmentBoundsForTextContainer:proposedLineFragment:glyphPosition:characterIndex:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        [[SevenTVManager sharedManager] log:@"DBG attachmentBoundsForTextContainer: introuvable sur NSTextAttachment"];
        return;
    }
    IMP orig = method_getImplementation(m);
    static NSUInteger s_resized = 0;
    static NSUInteger s_skipped = 0;
    method_setImplementation(m, imp_implementationWithBlock(^CGRect(id self_, NSTextContainer *tc, CGRect lineFrag, CGPoint glyphPos, NSUInteger charIdx) {
        CGRect r = ((CGRect(*)(id,SEL,NSTextContainer*,CGRect,CGPoint,NSUInteger))orig)(self_, sel, tc, lineFrag, glyphPos, charIdx);

        NSTextAttachment *attachment = (NSTextAttachment *)self_;
        UIImage *image = [attachment respondsToSelector:@selector(image)] ? attachment.image : nil;

        // DIAGNOSTIC : logger les 10 premiers appels pour voir charIdx et accessibilité textStorage
        {
            static NSUInteger s_diagCount = 0;
            if (s_diagCount < 10) {
                s_diagCount++;
                NSLayoutManager *lm_d = tc ? tc.layoutManager : nil;
                NSTextStorage  *ts_d  = lm_d ? lm_d.textStorage : nil;
                NSUInteger tsLen = ts_d ? ts_d.length : 0;
                NSString *prevCharsInfo = @"";
                if (ts_d && charIdx > 0 && charIdx < tsLen) {
                    // Vérifier si char[0] est un attachment
                    id att0 = [ts_d attribute:NSAttachmentAttributeName atIndex:0 effectiveRange:NULL];
                    // Vérifier si char avant charIdx est du texte ou attachment
                    id attPrev = (charIdx > 0) ? [ts_d attribute:NSAttachmentAttributeName atIndex:charIdx-1 effectiveRange:NULL] : nil;
                    prevCharsInfo = [NSString stringWithFormat:@" att[0]=%@ att[charIdx-1]=%@",
                        att0 ? @"YES" : @"NO",
                        attPrev ? @"YES" : @"NO"];
                }
                [[SevenTVManager sharedManager] log:[NSString stringWithFormat:
                    @"[BOUNDS-DIAG] #%lu charIdx=%lu r={%.0f,%.0f} tc=%@ lm=%@ ts=%@(len=%lu)%@",
                    (unsigned long)s_diagCount, (unsigned long)charIdx,
                    r.size.width, r.size.height,
                    tc ? @"OK" : @"nil",
                    lm_d ? @"OK" : @"nil",
                    ts_d ? @"OK" : @"nil", (unsigned long)tsLen,
                    prevCharsInfo]];
            }
        }

        // Condition : bounds "par defaut" (hauteur <=22pt, avant correction)
        // OU déjà à notre targetSize (rappel ultérieur sur un attachment
        // qu'on a déjà traité — voir commentaire détaillé dans ATTSIZE).
        CGFloat targetSizeForCheck2 = [[SevenTVManager sharedManager] targetEmoteSize];
        BOOL isDefaultSize2 = (r.size.height > 0 && r.size.height <= 22.0);
        BOOL isOurOwnPreviousSize2 = (r.size.height > 0 && fabs(r.size.height - targetSizeForCheck2) < 0.5);
        if (isDefaultSize2 || isOurOwnPreviousSize2) {

            // DUMP PONCTUEL : classe réelle + ivars/valeurs de l'attachment.
            // Objectif : trouver un identifiant (emoteID/URL/nom) directement
            // lisible sur l'objet, sans dépendre d'un matching par position
            // (fragile si l'espace de coordonnées ne correspond pas).
            static BOOL s_attachmentDumped = NO;
            if (!s_attachmentDumped && attachment) {
                s_attachmentDumped = YES;
                [[SevenTVManager sharedManager] log:@"🩻 ━━━━━ DUMP attachment (une seule fois) ━━━━━"];
                s7tv_dumpIvarValues(attachment, @"NSTextAttachment concret");
                [[SevenTVManager sharedManager] log:@"🩻 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"];
            }

            // Détection badge v2 : le textStorage Twitch commence par un char
            // spécial invisible (att[0]=NO mais pas alphanumérique).
            // Les badges viennent ensuite (charIdx=1, 2...).
            // Règle : si tous les chars avant charIdx sont soit des attachments,
            // soit des chars NON-alphanumériques (invisibles) → badge zone.
            // Dès qu'on trouve un char alphanumérique → username → zone message.
            NSLayoutManager *lm2 = tc ? tc.layoutManager : nil;
            NSTextStorage *ts2 = lm2 ? lm2.textStorage : nil;

            // ── DIAGNOSTIC Variante B : le marqueur invisible a-t-il survécu ? ──
            // Le marqueur (s'il existe) doit se trouver juste après le caractère
            // de remplacement de l'attachment (charIdx), donc à charIdx+1.
            if (ts2 && ts2.length > 0) {
                static NSUInteger s_tagDiagCount = 0;
                uint16_t shortID = 0;
                BOOL found = s7tv_decodeShortIDMarkerAt(ts2.string, charIdx + 1, &shortID);
                NSString *resolvedEmoteID = found ? [[SevenTVManager sharedManager] emoteIDForShortIndex:shortID] : nil;
                s_tagDiagCount++;
                if (s_tagDiagCount <= 60) {
                    NSString *result;
                    if (!found) {
                        result = @"❌ rien à cette position";
                    } else if (resolvedEmoteID) {
                        result = [NSString stringWithFormat:@"✅ shortID=%u → %@", shortID, resolvedEmoteID];
                    } else {
                        result = [NSString stringWithFormat:@"⚠️ shortID=%u décodé mais introuvable dans le dictionnaire", shortID];
                    }
                    [[SevenTVManager sharedManager] log:@"🏷️ [TAGID-DIAG] #%lu charIdx=%lu → %@",
                        (unsigned long)s_tagDiagCount, (unsigned long)charIdx, result];
                }
            }

            if (ts2 && ts2.length > 0 && charIdx <= ts2.length) {
                BOOL inBadgeZone = YES;
                NSCharacterSet *alphaNum = [NSCharacterSet alphanumericCharacterSet];
                for (NSUInteger i = 0; i < charIdx && i < ts2.length; i++) {
                    id attHere = [ts2 attribute:NSAttachmentAttributeName
                                        atIndex:i
                                 effectiveRange:NULL];
                    if (!attHere) {
                        NSString *cs = [ts2.string substringWithRange:NSMakeRange(i, 1)];
                        if (cs.length > 0 && [alphaNum characterIsMember:[cs characterAtIndex:0]]) {
                            inBadgeZone = NO;
                            break;
                        }
                        // Char spécial/invisible → on continue
                    }
                    // Attachment → on continue (badge précédent)
                }
                if (inBadgeZone) {
                    return r; // Badge — ne pas modifier les bounds
                }
            }

            CGFloat targetSize = [[SevenTVManager sharedManager] targetEmoteSize];
            // Réservation de layout : image.size reste quasi-systématiquement
            // {0,0} pour ces attachments (Twitch gère le rendu réel ailleurs,
            // au niveau CALayer — voir displayLayer:/setFrame:), donc on ne
            // compte plus dessus ici. Réservation simple = carré (largeur =
            // hauteur), qui sert de fallback neutre pour CoreText — le
            // chevauchement avec les emotes larges reste un problème ouvert
            // à ce niveau (voir tag ID invisible en cours d'implémentation).
            CGFloat width;
            NSString *widthSource;
            if (image && image.size.width > 0 && image.size.height > 0) {
                CGFloat ratio = image.size.width / image.size.height;
                width = targetSize * ratio;
                widthSource = @"image (ratio exact)";
            } else {
                width = targetSize;
                widthSource = @"carré (chevauchement géré par le décalage des voisins)";
            }
            CGRect newRect = CGRectMake(0, -6.0, width, targetSize);
            s_resized++;
            if (s_resized <= 300) {
                [[SevenTVManager sharedManager] log:[NSString stringWithFormat:
                    @"[BOUNDS] v3 resize #%lu origSize={%.0f,%.0f} largeur=%.1f (%@) orig=%@ new=%@",
                    (unsigned long)s_resized, r.size.width, r.size.height,
                    width, widthSource, NSStringFromCGRect(r), NSStringFromCGRect(newRect)]];
            }
            return newRect;
        }

        s_skipped++;
        if (s_skipped <= 5) {
            [[SevenTVManager sharedManager] log:[NSString stringWithFormat:
                @"[BOUNDS] skip #%lu r.h=%.0f (>22pt, ignore)",
                (unsigned long)s_skipped, r.size.height]];
        }
        return r;
    }));
    [[SevenTVManager sharedManager] log:@"[DBG] attachmentBoundsForTextContainer: hooke sur NSTextAttachment (v3 image.size)"];
}

static void s7tv_dbg_hookLayoutManagerAttachmentSize(void) {
    // - (void)setAttachmentSize:(CGSize)size forGlyphRange:(NSRange)range
    //
    // Strategie v3 : meme logique que hookAttachmentBounds — on utilise
    // directement image.size pour calculer le ratio sans avoir besoin du tag.
    Class cls = [NSLayoutManager class];
    SEL sel = NSSelectorFromString(@"setAttachmentSize:forGlyphRange:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        [[SevenTVManager sharedManager] log:@"[DBG] setAttachmentSize:forGlyphRange: introuvable sur NSLayoutManager"];
        return;
    }
    IMP orig = method_getImplementation(m);
    static NSUInteger s_resized = 0;
    static NSUInteger s_skipped = 0;
    method_setImplementation(m, imp_implementationWithBlock(^void(id self_, CGSize size, NSRange glyphRange) {
        CGSize finalSize = size;

        NSLayoutManager *lm = (NSLayoutManager *)self_;
        NSTextStorage *textStorage = lm.textStorage;
        if (textStorage && glyphRange.length > 0) {
            NSRange charRange = [lm characterRangeForGlyphRange:glyphRange actualGlyphRange:NULL];
            if (charRange.location != NSNotFound && charRange.location < textStorage.length) {
                id attachment = [textStorage attribute:NSAttachmentAttributeName atIndex:charRange.location effectiveRange:NULL];
                UIImage *image = (attachment && [attachment respondsToSelector:@selector(image)])
                    ? ((NSTextAttachment *)attachment).image : nil;

                // Condition : size "par defaut" (hauteur <=22pt, avant toute
                // correction de notre part) OU hauteur déjà égale à notre
                // targetSize (35pt typiquement) — c'est-à-dire un attachment
                // qu'ON a déjà traité lors d'un appel précédent. On le
                // retraite quand même : Twitch rappelle ce hook plusieurs
                // fois pour le même attachment, et notre propre hauteur
                // cible dépassait 22pt, ce qui faisait sauter (skip) tous
                // les rappels suivants — empêchant à vie la bascule vers le
                // ratio exact une fois l'image chargée. D'où le bug "reste
                // énorme même après refresh".
                CGFloat targetSizeForCheck = [[SevenTVManager sharedManager] targetEmoteSize];
                BOOL isDefaultSize = (size.height > 0 && size.height <= 22.0);
                BOOL isOurOwnPreviousSize = (size.height > 0 && fabs(size.height - targetSizeForCheck) < 0.5);
                if (isDefaultSize || isOurOwnPreviousSize) {
                    CGFloat targetSize = targetSizeForCheck;
                    // Même logique que BOUNDS (voir commentaire détaillé
                    // là-bas) : image.size en priorité si disponible, sinon
                    // carré simple — le chevauchement est géré ailleurs par
                    // le décalage des layers voisins.
                    CGFloat width;
                    NSString *widthSource;
                    if (image && image.size.width > 0 && image.size.height > 0) {
                        CGFloat ratio = image.size.width / image.size.height;
                        width = targetSize * ratio;
                        widthSource = @"image (ratio exact)";
                    } else {
                        width = targetSize;
                        widthSource = @"carré (chevauchement géré par le décalage des voisins)";
                    }
                    finalSize = CGSizeMake(width, targetSize);
                    s_resized++;
                    if (s_resized <= 300) {
                        [[SevenTVManager sharedManager] log:[NSString stringWithFormat:
                            @"[ATTSIZE] v3 resize #%lu origSize={%.0f,%.0f} largeur=%.1f (%@) new=%@",
                            (unsigned long)s_resized, size.width, size.height,
                            width, widthSource, NSStringFromCGSize(finalSize)]];
                    }
                } else {
                    s_skipped++;
                    if (s_skipped <= 5) {
                        [[SevenTVManager sharedManager] log:[NSString stringWithFormat:
                            @"[ATTSIZE] skip #%lu size.h=%.0f (>22pt, ignore)",
                            (unsigned long)s_skipped, size.height]];
                    }
                }
            }
        }

        ((void(*)(id,SEL,CGSize,NSRange))orig)(self_, sel, finalSize, glyphRange);
    }));
    [[SevenTVManager sharedManager] log:@"[DBG] setAttachmentSize:forGlyphRange: hooke sur NSLayoutManager (v3 image.size)"];
}

static void s7tv_dbg_hookTextStorageInit(void) {
    // DIAGNOSTIC PUR (aucun changement de comportement) : le hook
    // addAttribute:/setAttributes: ne se déclenche JAMAIS pour les
    // attachments d'emotes (confirmé en logs : 0 [TAG-EARLY], 0 [TAG-MISS]
    // malgré des dizaines d'emotes détectées). Twitch construit donc son
    // texte autrement (probablement une primitive bas niveau qui contourne
    // ces sélecteurs ObjC).
    //
    // Objectif ici : voir si le texte BRUT (avec les vrais noms d'emotes,
    // avant remplacement par le caractère U+FFFC) passe encore, à un
    // moment donné, par un des initializers standards de NSTextStorage/
    // NSMutableAttributedString. Si oui → on peut associer la liste
    // ordonnée des ratios directement sur CET objet (ts), sans dépendre
    // d'un matching par position. Si non → il faudra chercher ailleurs.
    void (^logIfInteresting)(NSString *, id) = ^(NSString *label, id str) {
        if (![str isKindOfClass:[NSString class]] && ![str isKindOfClass:[NSAttributedString class]]) return;
        NSString *s = [str isKindOfClass:[NSAttributedString class]] ? ((NSAttributedString *)str).string : str;
        if (s.length == 0) return;
        static NSUInteger s_count = 0;
        s_count++;
        if (s_count <= 25) {
            NSString *truncated = s.length > 80 ? [s substringToIndex:80] : s;
            [[SevenTVManager sharedManager] log:@"🐛 [TXT-INIT] %@ #%lu len=%lu texte=\"%@\"",
                label, (unsigned long)s_count, (unsigned long)s.length, truncated];
        }
    };

    Class classes[] = { [NSTextStorage class], [NSMutableAttributedString class] };
    NSString *labels[] = { @"NSTextStorage", @"NSMutableAttributedString" };
    for (int c = 0; c < 2; c++) {
        Class cls = classes[c];
        NSString *label = labels[c];

        SEL selInitStr = @selector(initWithString:);
        Method mInitStr = class_getInstanceMethod(cls, selInitStr);
        if (mInitStr) {
            IMP orig = method_getImplementation(mInitStr);
            method_setImplementation(mInitStr, imp_implementationWithBlock(^id(id self_, NSString *str) {
                id result = ((id(*)(id,SEL,NSString*))orig)(self_, selInitStr, str);
                logIfInteresting([label stringByAppendingString:@" initWithString:"], str);
                return result;
            }));
        }

        SEL selInitStrAttrs = @selector(initWithString:attributes:);
        Method mInitStrAttrs = class_getInstanceMethod(cls, selInitStrAttrs);
        if (mInitStrAttrs) {
            IMP orig = method_getImplementation(mInitStrAttrs);
            method_setImplementation(mInitStrAttrs, imp_implementationWithBlock(^id(id self_, NSString *str, NSDictionary *attrs) {
                id result = ((id(*)(id,SEL,NSString*,NSDictionary*))orig)(self_, selInitStrAttrs, str, attrs);
                logIfInteresting([label stringByAppendingString:@" initWithString:attributes:"], str);
                return result;
            }));
        }

        SEL selSetAttrStr = @selector(setAttributedString:);
        Method mSetAttrStr = class_getInstanceMethod(cls, selSetAttrStr);
        if (mSetAttrStr) {
            IMP orig = method_getImplementation(mSetAttrStr);
            method_setImplementation(mSetAttrStr, imp_implementationWithBlock(^void(id self_, NSAttributedString *attrStr) {
                logIfInteresting([label stringByAppendingString:@" setAttributedString:"], attrStr);
                ((void(*)(id,SEL,NSAttributedString*))orig)(self_, selSetAttrStr, attrStr);
            }));
        }

        SEL selReplaceChars = @selector(replaceCharactersInRange:withString:);
        Method mReplaceChars = class_getInstanceMethod(cls, selReplaceChars);
        if (mReplaceChars) {
            IMP orig = method_getImplementation(mReplaceChars);
            method_setImplementation(mReplaceChars, imp_implementationWithBlock(^void(id self_, NSRange range, NSString *str) {
                logIfInteresting([label stringByAppendingString:@" replaceCharactersInRange:withString:"], str);
                ((void(*)(id,SEL,NSRange,NSString*))orig)(self_, selReplaceChars, range, str);
            }));
        }
    }
    [[SevenTVManager sharedManager] log:@"✅ [DBG] Hooks diagnostic TXT-INIT posés (NSTextStorage/NSMutableAttributedString)"];
}

static IMP s_origAddAttributeIMP = NULL;
static SEL s_selAddAttribute = NULL;

static void s7tv_dbg_hookAddAttribute(void) {
    // Permet de voir, en temps réel, la VRAIE classe utilisée par Twitch
    // pour représenter une emote/attachment dans l'attributed string final,
    // et la range exacte où elle est insérée.
    Class cls = [NSMutableAttributedString class];

    // ── Tag ratio à l'insertion (fix chevauchement) ────────────────────
    // BOUNDS/ATTSIZE se déclenchent AVANT que l'image soit chargée
    // (attachment.image == nil) → ratio toujours carré en fallback, d'où
    // le chevauchement (le rendu visuel, lui, est corrigé plus tard par
    // displayLayer:/setFrame: une fois l'image prête — désync entre
    // "espace réservé" et "taille affichée").
    //
    // Fix : on connaît le ratio réel bien avant le chargement de l'image,
    // dès le parsing API 7TV (emote.width/height → SevenTVManager.emoteRatios,
    // voir injectSevenTVEmotesIntoIRCMessage:). On tague donc directement le
    // NSTextAttachment avec ce ratio ICI, à l'insertion — synchrone, aucune
    // dépendance au chargement de l'image. BOUNDS/ATTSIZE n'ont plus qu'à
    // lire ce tag en priorité.
    //
    // Appariement : emotePositions[@(range.location)] → emoteID. range.location
    // correspond à l'offset du caractère de remplacement dans le texte du
    // message (même espace de coordonnées que le tag "emotes=ID:start-end"
    // qu'on injecte nous-mêmes et que Twitch parse pour placer l'attachment).
    // Consommé (removeObjectForKey:) immédiatement après lecture pour éviter
    // toute contamination si un message ultérieur réutilise la même position.
    void (^tagAttachmentWithRatio)(id, NSRange) = ^(id attachment, NSRange range) {
        if (![attachment isKindOfClass:[NSTextAttachment class]]) return;
        if (objc_getAssociatedObject(attachment, &kS7TVEmoteRatioKey)) return; // déjà tagué

        SevenTVManager *mgr = [SevenTVManager sharedManager];
        NSString *emoteID = nil;
        NSArray *knownPositions = nil;
        @synchronized (mgr.emotePositions) {
            emoteID = mgr.emotePositions[@(range.location)];
            if (emoteID) {
                [mgr.emotePositions removeObjectForKey:@(range.location)];
            } else {
                knownPositions = [mgr.emotePositions.allKeys copy];
            }
        }
        if (!emoteID) {
            // DIAGNOSTIC : le matching par position a échoué. On logue les
            // positions actuellement connues pour comparer avec range.location
            // et déterminer s'il y a un décalage systématique (ex: longueur
            // du username/badges) plutôt qu'un vrai miss.
            static NSUInteger s_missCount = 0;
            s_missCount++;
            if (s_missCount <= 40) {
                [mgr log:@"🐛 [TAG-MISS] #%lu range.location=%lu range.length=%lu — positions connues=%@",
                    (unsigned long)s_missCount, (unsigned long)range.location,
                    (unsigned long)range.length, knownPositions ?: @[]];
            }
            return;
        }

        NSNumber *ratioNum = mgr.emoteRatios[emoteID];
        if (!ratioNum) return; // pas de donnée fiable → on laisse BOUNDS/ATTSIZE faire leur fallback habituel

        objc_setAssociatedObject(attachment, &kS7TVEmoteRatioKey, ratioNum, OBJC_ASSOCIATION_RETAIN);

        static NSUInteger s_tagCount = 0;
        s_tagCount++;
        if (s_tagCount <= 40) {
            [mgr log:@"🐛 [TAG-EARLY] ✅ #%lu emoteID=%@ ratio=%.3f pos=%lu (avant chargement image)",
                (unsigned long)s_tagCount, emoteID, ratioNum.floatValue, (unsigned long)range.location];
        }
    };

    // ── Invisibilité forcée du marqueur (Variante C) ──────────────────
    // Le marqueur (tag characters) a survécu au filtrage texte de Twitch
    // (contrairement aux variation selectors). Il faut maintenant le rendre
    // invisible NOUS-MÊMES, ici, en stylant sa range avec couleur
    // transparente + police quasi nulle. On appelle l'IMP ORIGINAL
    // (non swizzlé) pour éviter de re-déclencher notre propre hook en
    // boucle — s_origAddAttributeIMP est assigné juste après le swizzle
    // de sel1 ci-dessous, avant que ce bloc soit jamais exécuté.
    void (^hideMarkerIfPresent)(id, NSRange) = ^(id self_, NSRange range) {
        static NSUInteger s_hookCallCount = 0;
        s_hookCallCount++;
        if (s_hookCallCount <= 5 || s_hookCallCount % 200 == 0) {
            [[SevenTVManager sharedManager] log:@"🙈 [HIDE-DIAG] hook appelé #%lu (class=%@ range={%lu,%lu})",
                (unsigned long)s_hookCallCount, NSStringFromClass([self_ class]),
                (unsigned long)range.location, (unsigned long)range.length];
        }
        if (!s_origAddAttributeIMP || !s_selAddAttribute) return;
        NSString *full = [self_ string];
        if (!full) return;
        NSUInteger limit = MIN(full.length, range.location + range.length);
        if (range.location >= limit) return;
        NSRange found = s7tv_tagCharRunAt(full, range.location, limit);
        if (found.location == NSNotFound) return;
        void (*rawAdd)(id, SEL, NSString *, id, NSRange) =
            (void(*)(id, SEL, NSString *, id, NSRange))s_origAddAttributeIMP;
        rawAdd(self_, s_selAddAttribute, NSForegroundColorAttributeName, [UIColor clearColor], found);
        rawAdd(self_, s_selAddAttribute, NSFontAttributeName, [UIFont systemFontOfSize:0.1], found);
        rawAdd(self_, s_selAddAttribute, NSKernAttributeName, @(-0.1), found);
    };

    SEL sel1 = @selector(addAttribute:value:range:);
    Method m1 = class_getInstanceMethod(cls, sel1);
    if (m1) {
        IMP orig1 = method_getImplementation(m1);
        s_origAddAttributeIMP = orig1;
        s_selAddAttribute = sel1;
        static NSUInteger s_count1 = 0;
        method_setImplementation(m1, imp_implementationWithBlock(^void(id self_, NSString *attrName, id value, NSRange range) {
            if ([attrName isEqualToString:NSAttachmentAttributeName] || [value isKindOfClass:[NSTextAttachment class]]) {
                tagAttachmentWithRatio(value, range);
                s_count1++;
                if (s_count1 <= 40) {
                    [[SevenTVManager sharedManager] log:@"🐛 [DBG] addAttribute: NSTextAttachment #%lu class=%@ range={%lu,%lu} attrName=%@",
                        (unsigned long)s_count1, NSStringFromClass([value class]),
                        (unsigned long)range.location, (unsigned long)range.length, attrName];
                }
            }
            ((void(*)(id,SEL,NSString*,id,NSRange))orig1)(self_, sel1, attrName, value, range);
            hideMarkerIfPresent(self_, range);
        }));
    }

    SEL sel2 = @selector(setAttributes:range:);
    Method m2 = class_getInstanceMethod(cls, sel2);
    if (m2) {
        IMP orig2 = method_getImplementation(m2);
        static NSUInteger s_count2 = 0;
        method_setImplementation(m2, imp_implementationWithBlock(^void(id self_, NSDictionary *attrs, NSRange range) {
            id att = attrs[NSAttachmentAttributeName];
            if (att) {
                tagAttachmentWithRatio(att, range);
                s_count2++;
                if (s_count2 <= 40) {
                    [[SevenTVManager sharedManager] log:@"🐛 [DBG] setAttributes: NSTextAttachment #%lu class=%@ range={%lu,%lu}",
                        (unsigned long)s_count2, NSStringFromClass([att class]),
                        (unsigned long)range.location, (unsigned long)range.length];
                }
            }
            ((void(*)(id,SEL,NSDictionary*,NSRange))orig2)(self_, sel2, attrs, range);
            hideMarkerIfPresent(self_, range);
        }));
    }
    [[SevenTVManager sharedManager] log:@"✅ [DBG] addAttribute:/setAttributes: hookés sur NSMutableAttributedString (+ tag ratio précoce + invisibilité marqueur)"];
}

static void s7tv_hook_uiimage_decode_tagging(void) {
    // SevenTVURLProtocol tague la NSData brute (cached.data / data / gifData)
    // avec l'emoteID 7TV au moment de didLoadData:. On intercepte ici le
    // décodage UIImage générique pour propager ce tag (converti en ratio
    // via SevenTVManager.emoteRatios) sur l'UIImage résultante — c'est CE
    // tag que lisent ensuite les hooks attachmentBoundsForTextContainer:
    // et setAttachmentSize:forGlyphRange:.
    //
    // Ciblé car confirmé indépendant du pipeline NetworkImageRequester
    // (jamais appelé pour les attachments de chat) — ici on dépend
    // uniquement de +[UIImage imageWithData:] / -initWithData:, appelés
    // par n'importe quel chemin de décodage, y compris celui de Twitch.

    SevenTVManager *mgr = [SevenTVManager sharedManager];

    void (^tagResultIfNeeded)(NSData *, id) = ^(NSData *data, id resultImage) {
        if (!data || !resultImage) return;
        NSString *emoteID = objc_getAssociatedObject(data, &kS7TVEmoteIDOnDataKey);
        if (!emoteID) return;
        NSNumber *ratioNum = mgr.emoteRatios[emoteID];
        if (!ratioNum) ratioNum = @(1.0);
        objc_setAssociatedObject(resultImage, &kS7TVEmoteRatioKey, ratioNum, OBJC_ASSOCIATION_RETAIN);
        static NSUInteger s_tagCount = 0;
        s_tagCount++;
        if (s_tagCount <= 40) {
            [mgr log:@"🐛 [DECODE] ✅ Tag propagé NSData→UIImage #%lu emoteID=%@ ratio=%.3f",
                (unsigned long)s_tagCount, emoteID, ratioNum.floatValue];
        }
    };

    // +[UIImage imageWithData:]
    {
        SEL sel = @selector(imageWithData:);
        Method m = class_getClassMethod([UIImage class], sel);
        if (m) {
            IMP orig = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^UIImage *(id self_, NSData *data) {
                UIImage *result = ((UIImage *(*)(id,SEL,NSData*))orig)(self_, sel, data);
                tagResultIfNeeded(data, result);
                return result;
            }));
            [mgr log:@"✅ [DBG] +[UIImage imageWithData:] hooké"];
        }
    }

    // +[UIImage imageWithData:scale:]
    {
        SEL sel = @selector(imageWithData:scale:);
        Method m = class_getClassMethod([UIImage class], sel);
        if (m) {
            IMP orig = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^UIImage *(id self_, NSData *data, CGFloat scale) {
                UIImage *result = ((UIImage *(*)(id,SEL,NSData*,CGFloat))orig)(self_, sel, data, scale);
                tagResultIfNeeded(data, result);
                return result;
            }));
            [mgr log:@"✅ [DBG] +[UIImage imageWithData:scale:] hooké"];
        }
    }

    // -[UIImage initWithData:]
    {
        SEL sel = @selector(initWithData:);
        Method m = class_getInstanceMethod([UIImage class], sel);
        if (m) {
            IMP orig = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^UIImage *(id self_, NSData *data) {
                UIImage *result = ((UIImage *(*)(id,SEL,NSData*))orig)(self_, sel, data);
                tagResultIfNeeded(data, result);
                return result;
            }));
            [mgr log:@"✅ [DBG] -[UIImage initWithData:] hooké"];
        }
    }

    // -[UIImage initWithData:scale:]
    {
        SEL sel = @selector(initWithData:scale:);
        Method m = class_getInstanceMethod([UIImage class], sel);
        if (m) {
            IMP orig = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^UIImage *(id self_, NSData *data, CGFloat scale) {
                UIImage *result = ((UIImage *(*)(id,SEL,NSData*,CGFloat))orig)(self_, sel, data, scale);
                tagResultIfNeeded(data, result);
                return result;
            }));
            [mgr log:@"✅ [DBG] -[UIImage initWithData:scale:] hooké"];
        }
    }
}

static void s7tv_debug_dump_layout_system(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Les vrais points d'accroche identifiés sont :
        //   - NSTextAttachment.attachmentBoundsForTextContainer:...
        //   - Twitch.MessageStringLayoutManager.setAttachmentSize:forGlyphRange:
        // (sizeOfImageAttachmentAtCharacterIndex: n'est jamais appelée — abandonné)
        s7tv_hook_uiimage_decode_tagging();
        s7tv_dbg_hookAttachmentBounds();
        s7tv_dbg_hookLayoutManagerAttachmentSize();
        s7tv_dbg_hookAddAttribute();
        s7tv_dbg_hookTextStorageInit();
        s7tv_hook_displayLayer(); // installé tôt → actif dès le premier message

        // ── Hook setFrame: sur Twitch.ImageAttachmentLayer ────────────────
        // Twitch ignore attachmentBoundsForTextContainer: pour positionner ses
        // layers — il utilise sa propre logique (taille naturelle de l'image).
        // En hookant setFrame:, on intercepte synchronement au moment exact où
        // Twitch fixe le frame du layer → resize immédiat, zéro délai.
        Class ialClass = NSClassFromString(@"Twitch.ImageAttachmentLayer");
        if (ialClass) {
            SEL sfSel = @selector(setFrame:);
            Method sfM = class_getInstanceMethod(ialClass, sfSel);
            if (sfM) {
                IMP sfOrig = method_getImplementation(sfM);
                method_setImplementation(sfM, imp_implementationWithBlock(^void(CALayer *self_, CGRect newFrame) {
                    // Appel original d'abord
                    ((void(*)(id,SEL,CGRect))sfOrig)(self_, sfSel, newFrame);

                    // Twitch peut rappeler setFrame: juste après (image load async).
                    // On schedule la correction pour APRÈS que Twitch ait fini
                    // tous ses appels synchrones dans ce runloop.
                    CGFloat h = newFrame.size.height;
                    if (h <= 0 || h > 22.0) return;

                    CGFloat targetSize = [[SevenTVManager sharedManager] targetEmoteSize];

                    __weak CALayer *weakLayer = self_;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        CALayer *l = weakLayer;
                        if (!l) return;
                        // Si Twitch a réécrasé notre frame (encore <= 22pt), on corrige
                        if (l.frame.size.height <= 22.0) {
                            // Source de vérité : pixels réels du layer, lus MAINTENANT
                            // (au moment de l'application, pas au moment de l'appel
                            // setFrame: initial où l'image n'est souvent pas encore
                            // décodée/assignée à .contents).
                            CGFloat ratio = s7tv_ratioFromLayerContents(l);
                            if (ratio <= 0) return; // pas de donnée fiable → ne pas resize

                            CGFloat newW = targetSize * ratio;
                            CGRect f = l.frame;

                            CGRect corrected = CGRectMake(f.origin.x,
                                                          f.origin.y + (f.size.height - targetSize) / 2.0,
                                                          newW, targetSize);
                            [CATransaction begin];
                            [CATransaction setDisableActions:YES];
                            ((void(*)(id,SEL,CGRect))sfOrig)(l, sfSel, corrected);
                            [CATransaction commit];
                        }
                    });
                }));
                [[SevenTVManager sharedManager] log:@"✅ Hook setFrame: sur ImageAttachmentLayer OK (resize async-safe)"];
            } else {
                [[SevenTVManager sharedManager] log:@"⚠️ setFrame: introuvable sur ImageAttachmentLayer"];
            }
        } else {
            [[SevenTVManager sharedManager] log:@"⚠️ Twitch.ImageAttachmentLayer introuvable (hook setFrame: ignoré)"];
        }

        [[SevenTVManager sharedManager] log:@"✅ Hooks resize layout (bounds + attachmentSize + addAttribute + setFrame) actifs"];
    });
}


// ────────────────────────────────────────────────────────────
// MARK: - Point d'entrée __attribute__((constructor))
// ────────────────────────────────────────────────────────────


__attribute__((constructor))
static void TwitchSevenTVInit(void) {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr log:@"🔌 Chargement TwitchSevenTV v2.0 (substrate-free)..."];

    // Tap logger
    s7tv_swizzle([UIWindow class],
                 [UIWindow class],
                 @selector(sendEvent:),
                 @selector(s7tv_sendEvent:));

    // Verrou d'orientation (bouton Share hijacké)
    s7tv_swizzle_orientation_lock();

    // Injection bouton dans ChatInputView
    s7tv_swizzle([UIView class],
                 [UIView class],
                 @selector(didMoveToWindow),
                 @selector(s7tv_didMoveToWindow));

    // URLProtocol (redirection CDN 7TV)
    s7tv_swizzle_protocol_classes();

    // Interception réponses GQL Twitch
    s7tv_swizzle_session();

    // Interception IRC WebSocket
    s7tv_swizzle_websocket();

    // Hook NetworkImageRequester (lecture seule, log URLs 7TV)
    s7tv_hook_network_image_requester();
    // s7tv_hook_emote_size() retiré : sizeOfImageAttachmentAtCharacterIndex: n'est
    // jamais appelée par Twitch (confirmé par dump debug). Remplacé par
    // s7tv_debug_dump_layout_system() qui installe les vrais hooks
    // (attachmentBoundsForTextContainer: + setAttachmentSize:forGlyphRange:).
    s7tv_debug_dump_layout_system();

    // Section 7TV dans les paramètres Twitch
    s7tv_swizzle_account_menu();

    // Blocked URLs + HLS Sanitizer


    // Setup sur le main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SevenTVManager sharedManager] setup];
        [NSURLProtocol registerClass:[SevenTVURLProtocol class]];
        [[SevenTVManager sharedManager] log:@"✅ SevenTVManager prêt, URLProtocol enregistré"];

        // Démarrer le local proxy si activé

        // ── Hook willDisplayCell sur ChatTranscriptView ──────────────────
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            Class transcriptClass = NSClassFromString(@"Twitch.ChatTranscriptView");
            if (!transcriptClass) return;

            SEL origSel = @selector(tableView:willDisplayCell:forRowAtIndexPath:);
            Method origMethod = class_getInstanceMethod(transcriptClass, origSel);
            if (!origMethod) return;

            IMP origIMP = method_getImplementation(origMethod);

            IMP newIMP = imp_implementationWithBlock(^(id self_tv,
                                                       UITableView *tableView,
                                                       UITableViewCell *cell,
                                                       NSIndexPath *indexPath) {
                // Appel original
                ((void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))origIMP)
                    (self_tv, origSel, tableView, cell, indexPath);

                // Seulement pour ChatMessageTableViewCell
                if (![NSStringFromClass([cell class]) isEqualToString:@"Twitch.ChatMessageTableViewCell"]) return;

                // setFrame: hook gère le resize synchrone — dispatch_async
                // sert juste à laisser le runloop finir le layout courant avant
                // le BFS, sans délai visible.
                __weak UITableViewCell *weakCell = cell;
                __weak UITableView     *weakTV   = tableView;
                dispatch_async(dispatch_get_main_queue(), ^{
                    UITableViewCell *cell = weakCell;
                    UITableView     *tv   = weakTV;
                    // Guards stream-close : si l'un des deux objets est mort,
                    // ou si la cellule n'est plus dans la fenêtre (stream fermé),
                    // ou si la cellule a été sortie de la table (recyclage en cours)
                    // → on abandonne pour éviter EXC_BAD_ACCESS sur les ivars Swift.
                    if (!cell || !tv) return;
                    if (!cell.window || !tv.window) return;
                    if (cell.superview != tv) return;

                    // NOTE : le dimensionnement des emotes (ratio, taille) est désormais
                    // entièrement géré en amont par le pipeline BOUNDS/ATTSIZE/setFrame/
                    // displayLayer (voir s7tv_dbg_hookAttachmentBounds,
                    // s7tv_dbg_hookLayoutManagerAttachmentSize, s7tv_hook_displayLayer,
                    // et le hook setFrame: sur Twitch.ImageAttachmentLayer), qui lisent
                    // tous le ratio depuis les vraies dimensions (image.size / pixels
                    // réels du layer) — source fiable, disponible dès le décodage.
                    // L'ancienne approche ici (matching par mot du texte affiché pour
                    // reconstruire un ordre d'emotes) a été retirée : elle ne fonctionnait
                    // jamais car le texte affiché remplace chaque emote par le caractère
                    // de remplacement U+FFFC, pas par son nom — orderedRatios.count était
                    // donc toujours 0 (confirmé en logs : "mismatch ... ratios=0").
                    // Ce qui suit ne s'occupe plus que du démarrage de l'animation GIF.

                    // Collecter les emote layers via l'API publique CALayer uniquement
                    // (plus de raw pointer → élimine le crash objc_retain sur Swift storage)
                    NSMutableArray<CALayer *> *emoteLayers = [NSMutableArray array];
                    NSMutableArray<CALayer *> *layerQueue = [NSMutableArray arrayWithArray:cell.layer.sublayers];
                    while (layerQueue.count > 0) {
                        CALayer *l = layerQueue[0];
                        [layerQueue removeObjectAtIndex:0];
                        // Chercher les layers qui ont un sublayer "Animated" (= emote 7TV)
                        for (CALayer *sub in l.sublayers) {
                            if ([NSStringFromClass(object_getClass(sub)) containsString:@"Animated"]) {
                                [emoteLayers addObject:l];
                                break;
                            }
                        }
                        if (l.sublayers) [layerQueue addObjectsFromArray:l.sublayers];
                    }

                    if (emoteLayers.count == 0) return;

                    // Dump diagnostic (une seule fois) pour vérifier les noms réels
                    // d'ivars/classes sur CETTE version de l'app.
                    s7tv_dumpAnimationArchitectureOnce(emoteLayers.firstObject);

                    // ────────────────────────────────────────────────────────
                    // Hook initWithFPS: — piste prioritaire non explorée du
                    // récap. Confirmé : les emotes WebP se chargent (signature
                    // validée), startAnimating est appelé, displayLayer: se
                    // déclenche, MAIS l'animation reste figée sur une frame
                    // fixe (différente par occurrence — donc le décodage WebP
                    // fonctionne, mais le timer/scheduler d'animation interne
                    // ne progresse jamais après le premier rendu).
                    // initWithFPS: est le seul point où Twitch configure ce
                    // qui pilote la cadence d'animation. FPS=0 expliquerait
                    // exactement ce symptôme (layer créé mais jamais "tické").
                    static BOOL s_initWithFPSHooked = NO;
                    if (!s_initWithFPSHooked) {
                        Class animLayerClsForFPS = NSClassFromString(@"Twitch.AnimatedImageAttachmentLayer");
                        if (animLayerClsForFPS) {
                            SEL fpsSel = NSSelectorFromString(@"initWithFPS:");
                            Method fpsM = class_getInstanceMethod(animLayerClsForFPS, fpsSel);
                            if (fpsM) {
                                IMP origFPSIMP = method_getImplementation(fpsM);
                                method_setImplementation(fpsM, imp_implementationWithBlock(^id(id selfObj, double fps) {
                                    id result = nil;
                                    @try {
                                        result = ((id(*)(id,SEL,double))origFPSIMP)(selfObj, fpsSel, fps);
                                    } @catch(...) {
                                        result = selfObj;
                                    }
                                    static NSInteger s_fpsLogCount = 0;
                                    if (s_fpsLogCount < 10) {
                                        s_fpsLogCount++;
                                        [[SevenTVManager sharedManager] log:[NSString stringWithFormat:
                                            @"🩻 initWithFPS: appelé avec fps=%.3f → classe=%@ (log %ld/10)",
                                            fps, NSStringFromClass(object_getClass(result ?: selfObj)),
                                            (long)s_fpsLogCount]];
                                    }
                                    return result;
                                }));
                                s_initWithFPSHooked = YES;
                                [[SevenTVManager sharedManager] log:@"✅ Hook initWithFPS: sur AnimatedImageAttachmentLayer OK"];
                            } else {
                                [[SevenTVManager sharedManager] log:@"⚠️ initWithFPS: introuvable sur AnimatedImageAttachmentLayer"];
                            }
                        }
                    }
                    // ────────────────────────────────────────────────────────

                    // Fallback : si displayLayer: hook n'était pas encore installé
                    // à t=3s (classe pas encore chargée), on réessaie ici.
                    static BOOL s_displayLayerHooked = NO;
                    if (!s_displayLayerHooked) {
                        s7tv_hook_displayLayer();
                        s_displayLayerHooked = YES;
                    }

                    // Filet de sécurité complémentaire : polling court (ivar "animatedImageLayer"
                    // de l'ImageAttachmentLayer englobant, accès par nom — pas d'offset en dur).
                    // Couvre le cas où displayLayer: ne se déclenche pas (image pas encore chargée
                    // au moment du willDisplayCell).
                    for (CALayer *outerEmoteLayer in emoteLayers) {
                        s7tv_retryStartAnimating(outerEmoteLayer, 6); // ~1.5s de tentatives
                    }

                    // ─────────────────────────────────────────────────────────────
                    // Le resize de taille/ratio n'a plus lieu ici (voir note plus haut) —
                    // uniquement le démarrage de l'animation GIF ci-dessus.

                });
            });

            method_setImplementation(origMethod, newIMP);
            [[SevenTVManager sharedManager] log:@"✅ willDisplayCell hooké (dispatch_async, setFrame: hook actif)"];

            // Observer : quand le slider change la taille, on force un reloadData
            // sur toutes les ChatTranscriptView visibles.
            // L'objet retourné est stocké dans une static pour éviter le leak
            // et garantir qu'on ne s'enregistre qu'une seule fois.
            static id s_emoteSizeObserver = nil;
            if (s_emoteSizeObserver) return; // déjà enregistré
            s_emoteSizeObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:@"S7TVEmoteSizeDidChangeNotification"
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) {
                // Parcourir toutes les fenêtres et trouver les UITableView
                // dans les ChatTranscriptView
                for (UIWindow *win in [UIApplication sharedApplication].windows) {
                    NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
                    while (stack.count) {
                        UIView *v = stack[0];
                        [stack removeObjectAtIndex:0];
                        if ([NSStringFromClass([v class]) isEqualToString:@"Twitch.ChatTranscriptView"]) {
                            for (UIView *sub in v.subviews) {
                                if ([sub isKindOfClass:[UITableView class]]) {
                                    UITableView *tv = (UITableView *)sub;
                                    NSArray *visible = [tv indexPathsForVisibleRows];
                                    if (visible.count) {
                                        [tv reloadRowsAtIndexPaths:visible
                                               withRowAnimation:UITableViewRowAnimationNone];
                                    }
                                }
                            }
                        }
                        [stack addObjectsFromArray:v.subviews];
                    }
                }
            }];
        });
        // ─────────────────────────────────────────────────────────────────

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [[SevenTVManager sharedManager] addSettingsButton];
                [[SevenTVManager sharedManager] log:@"✅ Bouton 7TV ajouté"];
            }
        );
    });
}
