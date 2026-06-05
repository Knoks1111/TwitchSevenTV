/*
 * TweakSevenTV.m  —  Substrate-FREE version
 *
 * CORRECTIFS v1.4:
 *   Fix A — ROOMSTATE: room-id depuis IRC
 *   Fix B — URLProtocol: swizzle protocolClasses
 *
 * CORRECTIFS v2.0 (réécriture complète):
 *
 *   Fix BADGES — Système de tag sur UIImage
 *     Avant : s7tv_setImage: traitait TOUTES les UIImageViews (badges,
 *     avatars, thumbnails…) dont la hauteur était entre 10 et 80pt.
 *     Il réinitialisait l'attributedText → détruisait et recréait les
 *     UIImageViews de badges → environ 50% disparaissaient.
 *     Après : dans s7tv_imageWithData:, on pose un associated object
 *     kS7TVIsOurEmoteKey sur CHAQUE UIImage décodée depuis un WebP ou
 *     GIF provenant du CDN 7TV. Dans s7tv_setImage:, on ignore tout
 *     ce qui n'a pas ce tag → badges et autres assets Twitch intacts.
 *
 *   Fix ANIMATIONS (voie UIImageView) — startAnimating
 *     Avant : CADisplayLink avec selector s7tv_displayLinkTick:. Causait
 *     un retain cycle (UIImageView ↔ CADisplayLink via associated object)
 *     ET pouvait planter si la sous-classe concrète de Twitch ne dispatche
 *     pas le sélecteur depuis la bonne IMP.
 *     Après : on utilise UIImageView.animationImages + startAnimating.
 *     UIKit gère l'animation nativement (CAKeyframeAnimation sur
 *     layer.contents), pas de retain cycle, pas de crash de selector.
 *
 *   Fix ANIMATIONS (voie CoreText/NSTextAttachment) — getter + ticker
 *     CoreText ne crée pas toujours de UIImageView pour les NSTextAttachment
 *     (dépend de la version iOS et de l'implémentation de Twitch). Pour
 *     couvrir ce cas, on swizzle :
 *       • NSTextAttachment.setImage: → détecte les images animées 7TV,
 *         stocke les frames dans un associated object sur l'attachment.
 *       • NSTextAttachment.image (getter) → retourne la frame courante
 *         calculée via CACurrentMediaTime().
 *     Un CADisplayLink global (S7TVAnimTicker) appelle setNeedsDisplay
 *     toutes les ~20fps sur les UITextView/UILabel visibles du chat.
 *     CoreText re-render → appelle attachment.image → frame correcte → ✅
 */

#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"


// ────────────────────────────────────────────────────────────
// MARK: - Clés associated objects (adresses uniques = clés)
// ────────────────────────────────────────────────────────────

// Sur UIImage : marque une image décodée depuis un WebP/GIF 7TV
static const char kS7TVIsOurEmoteKey  = 0;

// Sur UIImageView : display link restant (pour invalidation au recyclage)
static const char kS7TVDisplayLinkKey = 1;

// Sur UITextView / UILabel : guard anti-boucle attributedText reset
static const char kS7TVReloadGuard    = 2;

// Sur NSTextAttachment : frames de l'animation (NSArray<UIImage*>)
static const char kS7TVAttachFrames   = 3;
// Sur NSTextAttachment : durée totale de l'animation (NSTimeInterval)
static const char kS7TVAttachDuration = 4;


// ────────────────────────────────────────────────────────────
// MARK: - UIImage (SevenTVGIF) — Décodage WebP/GIF animé
//
// Swizzle de [UIImage imageWithData:] pour décoder les WebP et GIF
// multi-frames provenant du CDN 7TV.
//
// Fast path : on vérifie les magic bytes AVANT d'appeler
// CGImageSourceCreateWithData (coûteux). Pour tout format qui n'est
// ni WebP ni GIF → appel immédiat à l'original, zéro overhead.
//
// Tag : CHAQUE image décodée ici reçoit kS7TVIsOurEmoteKey=@YES.
// s7tv_setImage: ignore toute image sans ce tag → badges intacts.
// ────────────────────────────────────────────────────────────

@interface UIImage (SevenTVGIF)
+ (UIImage *)s7tv_imageWithData:(NSData *)data;
@end

@implementation UIImage (SevenTVGIF)

+ (UIImage *)s7tv_imageWithData:(NSData *)data {
    if (data.length < 4) {
        return [self s7tv_imageWithData:data];
    }

    const uint8_t *b = (const uint8_t *)data.bytes;

    BOOL isGIF  = (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38);
    BOOL isWebP = (data.length >= 12 &&
                   b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
                   b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50);

    // Ni GIF ni WebP → pas une image 7TV → appel original immédiat
    if (!isGIF && !isWebP) {
        return [self s7tv_imageWithData:data];
    }

    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) {
        return [self s7tv_imageWithData:data];
    }

    size_t count = CGImageSourceGetCount(src);
    UIImage *result = nil;

    if (count > 1) {
        // ── Image animée (multi-frames) ───────────────────────────────────────
        NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:count];
        NSTimeInterval totalDuration = 0.0;

        for (size_t i = 0; i < count; i++) {
            CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, i, NULL);
            if (cgImg) {
                UIImage *frame = [UIImage imageWithCGImage:cgImg
                                                     scale:1.0
                                               orientation:UIImageOrientationUp];
                [frames addObject:frame];
                CFRelease(cgImg);
            }

            // Durée de la frame (même clé pour GIF et WebP)
            NSDictionary *props = (__bridge_transfer NSDictionary *)
                CGImageSourceCopyPropertiesAtIndex(src, i, NULL);
            NSDictionary *gifProps  = props[(__bridge NSString *)kCGImagePropertyGIFDictionary];
            NSDictionary *webpProps = props[(__bridge NSString *)kCGImagePropertyWebPDictionary];
            NSDictionary *animProps = gifProps ?: webpProps;

            NSNumber *unclampedDelay =
                animProps[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime];
            NSNumber *clampedDelay =
                animProps[(__bridge NSString *)kCGImagePropertyGIFDelayTime];

            double frameDelay = (unclampedDelay ?: clampedDelay).doubleValue;
            totalDuration += (frameDelay > 0.01) ? frameDelay : 0.1; // sécurité: min 100ms/frame
        }
        CFRelease(src);

        if (frames.count > 1) {
            result = [UIImage animatedImageWithImages:frames
                                            duration:totalDuration];
        } else if (frames.count == 1) {
            result = frames[0];
        }

    } else if (count == 1) {
        // ── Image statique (single frame WebP) ───────────────────────────────
        CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        CFRelease(src);
        if (cgImg) {
            result = [UIImage imageWithCGImage:cgImg scale:1.0
                                   orientation:UIImageOrientationUp];
            CFRelease(cgImg);
        }
    } else {
        CFRelease(src);
    }

    if (!result) {
        return [self s7tv_imageWithData:data];
    }

    // ── TAG 7TV : marque cette image comme provenant de notre décodeur ────────
    // s7tv_setImage: vérifie ce tag → ignore tout ce qui ne vient pas de 7TV.
    // Garantit que les badges, avatars et autres images Twitch ne sont jamais
    // modifiés par notre code de redimensionnement/animation.
    objc_setAssociatedObject(result, &kS7TVIsOurEmoteKey,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [[SevenTVManager sharedManager]
        log:@"🖼 imageWithData: WebP/GIF décodé — %zu frame(s), dur=%.2fs",
        (size_t)(result.images.count ?: 1), result.duration];

    return result;
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - S7TVAnimTicker — Ticker global pour l'animation NSTextAttachment
//
// CADisplayLink 20fps qui appelle setNeedsDisplay sur toutes les
// UITextView et UILabel visibles dans la zone de chat.
// CoreText redessine → appelle NSTextAttachment.image (getter swizzlé)
// → reçoit la frame courante → emote animée. ✅
//
// Démarre automatiquement quand noteAnimatedAttachment est appelé.
// Ne démarre PAS si showAnimated est désactivé.
// ────────────────────────────────────────────────────────────

@interface S7TVAnimTicker : NSObject
+ (instancetype)shared;
- (void)noteAnimatedAttachment;  // called when an animated attachment is registered
- (void)stop;
@end

@implementation S7TVAnimTicker {
    CADisplayLink *_link;
}

+ (instancetype)shared {
    static S7TVAnimTicker *s = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[S7TVAnimTicker alloc] init]; });
    return s;
}

- (void)noteAnimatedAttachment {
    if (![SevenTVManager sharedManager].showAnimated) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_link) return;
        self->_link = [CADisplayLink displayLinkWithTarget:self
                                                  selector:@selector(tick:)];
        self->_link.preferredFramesPerSecond = 20;
        [self->_link addToRunLoop:[NSRunLoop mainRunLoop]
                          forMode:NSRunLoopCommonModes];
        [[SevenTVManager sharedManager] log:@"🎬 AnimTicker démarré (20fps)"];
    });
}

- (void)stop {
    [_link invalidate];
    _link = nil;
}

- (void)tick:(CADisplayLink *)dl {
    // Trouver la clé window
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    if (!keyWindow) return;

    // Trouver le plus grand UIScrollView avec overflow = chat
    UIScrollView *chatView = nil;
    CGFloat bestArea = 0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:keyWindow];
    while (queue.count > 0) {
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UIScrollView class]] && !v.isHidden && v.alpha > 0.01) {
            UIScrollView *sv = (UIScrollView *)v;
            CGFloat area    = sv.bounds.size.width * sv.bounds.size.height;
            CGFloat overflow = sv.contentSize.height - sv.bounds.size.height;
            if (area > bestArea && overflow > 100) { bestArea = area; chatView = sv; }
        }
        for (UIView *s in v.subviews) if (!s.isHidden) [queue addObject:s];
    }
    if (!chatView) return;

    // BFS : setNeedsDisplay sur UITextView et UILabel dans le chat
    // CoreText redessine → appelle attachment.image → frame courante
    NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithArray:chatView.subviews];
    while (bfs.count > 0) {
        UIView *v = bfs.firstObject; [bfs removeObjectAtIndex:0];
        if ([v isKindOfClass:[UITextView class]] || [v isKindOfClass:[UILabel class]]) {
            [v setNeedsDisplay];
            // Ne pas descendre dans les sous-vues du texte
            continue;
        }
        for (UIView *s in v.subviews) if (!s.isHidden) [bfs addObject:s];
    }
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - NSTextAttachment (SevenTVAnim)
//
// Deux swizzles sur NSTextAttachment :
//
//   setImage: → si l'image est une 7TV animée (kS7TVIsOurEmoteKey + images.count>1),
//               stocker les frames + durée dans des associated objects.
//               Démarre le S7TVAnimTicker.
//
//   image (getter) → si des frames sont stockées, retourner la frame
//               courante calculée via CACurrentMediaTime(). Sinon, appel
//               original. Coût : ~1 associated object lookup + fmod + indexing.
//
// SÉCURITÉ : ne modifie le comportement QUE pour les attachments 7TV animés.
// Tous les autres attachments (emotes Twitch natives, images inline…)
// passent directement par le getter original.
// ────────────────────────────────────────────────────────────

@interface NSTextAttachment (SevenTVAnim)
- (void)s7tv_setAttachImage:(UIImage *)image;
- (UIImage *)s7tv_getAttachImage;
@end

@implementation NSTextAttachment (SevenTVAnim)

- (void)s7tv_setAttachImage:(UIImage *)image {
    [self s7tv_setAttachImage:image]; // appel original

    // Vérifier si c'est une image animée 7TV
    if (image
        && objc_getAssociatedObject(image, &kS7TVIsOurEmoteKey)
        && image.images.count > 1)
    {
        NSTimeInterval dur = image.duration > 0 ? image.duration : 1.0;
        objc_setAssociatedObject(self, &kS7TVAttachFrames,
                                 image.images, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kS7TVAttachDuration,
                                 @(dur), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Démarrer le ticker global
        [S7TVAnimTicker.shared noteAnimatedAttachment];
        [[SevenTVManager sharedManager]
            log:@"🎭 NSTextAttachment animé enregistré — %lu frames %.2fs",
            (unsigned long)image.images.count, dur];
    } else {
        // Effacer les frames si l'image change pour une image statique
        objc_setAssociatedObject(self, &kS7TVAttachFrames,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (UIImage *)s7tv_getAttachImage {
    NSArray<UIImage *> *frames = objc_getAssociatedObject(self, &kS7TVAttachFrames);
    if (!frames.count) {
        return [self s7tv_getAttachImage]; // original getter
    }

    NSNumber *durNum = objc_getAssociatedObject(self, &kS7TVAttachDuration);
    NSTimeInterval dur = durNum.doubleValue;
    if (dur <= 0) return frames[0];

    // Calculer la frame courante sans aucun état stocké
    CFTimeInterval t    = fmod(CACurrentMediaTime(), dur);
    NSInteger      idx  = (NSInteger)((t / dur) * (double)frames.count);
    if (idx < 0)                        idx = 0;
    if (idx >= (NSInteger)frames.count) idx = (NSInteger)frames.count - 1;
    return frames[idx];
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - UIImageView (SevenTVAnimation) — Animation et redimensionnement
//
// Swizzle de UIImageView.setImage: pour :
//   1. GARDER uniquement les images 7TV (kS7TVIsOurEmoteKey) →
//      badges, avatars, thumbnails ignorés.
//   2. Démarrer l'animation UIKit (animationImages + startAnimating)
//      pour les images multi-frames.
//   3. Corriger les dimensions de la UIImageView et du NSTextAttachment
//      pour les images statiques (ratio correct, pas de tronquage).
//   4. Forcer CoreText à recalculer le layout via attributedText reset.
// ────────────────────────────────────────────────────────────

@interface UIImageView (SevenTVAnimation)
- (void)s7tv_setImage:(UIImage *)image;
@end

@implementation UIImageView (SevenTVAnimation)

- (void)s7tv_setImage:(UIImage *)image {
    [self s7tv_setImage:image]; // appel original

    // ── GUARD 1: image nulle → rien à faire ──────────────────────────────────
    if (!image) return;

    // ── GUARD 2: TAG — n'agir que sur les images décodées par s7tv_imageWithData:
    // Cela exclut badges, avatars, miniatures, emotes Twitch natives, etc.
    // SEULES les images WebP/GIF provenant du CDN 7TV ont ce tag.
    if (!objc_getAssociatedObject(image, &kS7TVIsOurEmoteKey)) return;

    // ── Invalider un éventuel ancien display link (recyclage de cellule) ─────
    CADisplayLink *oldLink = objc_getAssociatedObject(self, &kS7TVDisplayLinkKey);
    if (oldLink) {
        [oldLink invalidate];
        objc_setAssociatedObject(self, &kS7TVDisplayLinkKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // ── PATH A : IMAGE ANIMÉE → UIKit native animation ────────────────────────
    if (image.images.count > 1) {
        // UIImageView.animationImages + startAnimating utilise une CAKeyframeAnimation
        // sur layer.contents → géré par UIKit, pas de retain cycle, pas de crash
        // de selector, fonctionne quelle que soit la sous-classe UIImageView.
        self.animationImages  = image.images;
        self.animationDuration = image.duration > 0 ? image.duration : 1.0;
        self.animationRepeatCount = 0; // infini
        [self startAnimating];

        [[SevenTVManager sharedManager]
            log:@"▶️ startAnimating — %lu frames %.2fs sur %@",
            (unsigned long)image.images.count, self.animationDuration,
            NSStringFromClass([self class])];

        // Pas de reset attributedText pour les animées : setNeedsDisplay
        // est géré par S7TVAnimTicker via NSTextAttachment getter.
        return;
    }

    // ── PATH B : IMAGE STATIQUE → redimensionnement + reset CoreText ──────────

    CGFloat imgW = image.size.width, imgH = image.size.height;
    if (imgH <= 0 || imgW <= 0) return;

    // Filtrer les contextes qui ne sont pas du chat (barre de navigation, onglets…)
    NSString *superviewClass = NSStringFromClass([self.superview class]);
    if ([superviewClass containsString:@"TabBar"]       ||
        [superviewClass containsString:@"NavigationBar"] ||
        [superviewClass containsString:@"ToolBar"])      return;

    CGFloat viewH = self.bounds.size.height > 0
        ? self.bounds.size.height : self.frame.size.height;
    if (viewH < 8 || viewH > 100.0) return;

    CGFloat ratio = imgW / imgH;

    UIView  *capturedSuper = self.superview;

    void (^doWork)(void) = ^{

        // ── Calculer la taille cible (4x.webp → affichage 1x) ────────────────
        // Les emotes 7TV sont servies en 4x → diviser par 4 pour la taille pt.
        const CGFloat kCDNScale = 4.0;
        CGFloat targetW = ceilf(imgW / kCDNScale);
        CGFloat targetH = ceilf(imgH / kCDNScale);

        // Garde-fou: si la taille calculée est hors plage, fallback sur viewH
        if (targetH < 8 || targetH > 60) {
            targetH = viewH > 0 ? viewH : 28.0;
            targetW = ceilf(targetH * ratio);
        }

        // ── Ajuster les contraintes / frame ──────────────────────────────────
        BOOL widthFixed = NO, heightFixed = NO;

        for (NSLayoutConstraint *c in self.constraints) {
            if (c.secondItem) continue;
            if (c.firstAttribute == NSLayoutAttributeWidth)  { c.constant = targetW; widthFixed  = YES; }
            if (c.firstAttribute == NSLayoutAttributeHeight) { c.constant = targetH; heightFixed = YES; }
        }
        for (NSLayoutConstraint *c in (self.superview.constraints ?: @[])) {
            if (c.firstItem != self && c.secondItem != self) continue;
            if (c.firstAttribute == NSLayoutAttributeWidth  || c.secondAttribute == NSLayoutAttributeWidth)
                { c.constant = targetW; widthFixed  = YES; }
            if (c.firstAttribute == NSLayoutAttributeHeight || c.secondAttribute == NSLayoutAttributeHeight)
                { c.constant = targetH; heightFixed = YES; }
        }
        if (!widthFixed || !heightFixed) {
            CGRect f = self.frame;
            if (!widthFixed)  f.size.width  = targetW;
            if (!heightFixed) f.size.height = targetH;
            self.frame = f;
        }
        self.contentMode = UIViewContentModeScaleAspectFit;

        // ── Corriger les bounds du NSTextAttachment ───────────────────────────
        // Avant le reset attributedText, on corrige la taille de l'attachment
        // pour que CoreText calcule le bon layout dès le premier redraw.
        {
            UIView *scan = capturedSuper;
            for (int d = 0; d < 12 && scan; d++, scan = scan.superview) {
                if (![scan isKindOfClass:[UITextView class]]) continue;
                UITextView *tv = (UITextView *)scan;
                NSAttributedString *attrStr = tv.attributedText;
                if (!attrStr.length) break;
                [attrStr enumerateAttribute:NSAttachmentAttributeName
                                    inRange:NSMakeRange(0, attrStr.length)
                                    options:0
                                 usingBlock:^(id att, NSRange r, BOOL *stop) {
                    if (![att isKindOfClass:[NSTextAttachment class]]) return;
                    NSTextAttachment *a = (NSTextAttachment *)att;
                    if (a.image == image) {
                        a.bounds = CGRectMake(0, -4.0, targetW, targetH);
                        *stop = YES;
                    }
                }];
                break;
            }
        }

        // ── Reset attributedText pour forcer CoreText à recalculer ───────────
        UIView *v = capturedSuper;
        for (int d = 0; d < 12 && v; d++, v = v.superview) {

            if ([v isKindOfClass:[UITextView class]]) {
                UITextView *tv2 = (UITextView *)v;
                if (objc_getAssociatedObject(tv2, &kS7TVReloadGuard)) break;
                objc_setAssociatedObject(tv2, &kS7TVReloadGuard, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSAttributedString *saved = tv2.attributedText;
                if (saved.length > 0) {
                    tv2.attributedText = nil;
                    tv2.attributedText = saved;
                    [[SevenTVManager sharedManager] log:@"♻️ UITextView attributedText reset"];
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    objc_setAssociatedObject(tv2, &kS7TVReloadGuard, nil,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                });
                return;
            }

            if ([v isKindOfClass:[UILabel class]]) {
                UILabel *lbl = (UILabel *)v;
                if (objc_getAssociatedObject(lbl, &kS7TVReloadGuard)) break;
                objc_setAssociatedObject(lbl, &kS7TVReloadGuard, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSAttributedString *saved = lbl.attributedText;
                if (saved.length > 0) {
                    lbl.attributedText = nil;
                    lbl.attributedText = saved;
                    [[SevenTVManager sharedManager] log:@"♻️ UILabel attributedText reset"];
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    objc_setAssociatedObject(lbl, &kS7TVReloadGuard, nil,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                });
                return;
            }
        }
    };

    if ([NSThread isMainThread]) {
        doWork();
    } else {
        dispatch_async(dispatch_get_main_queue(), doWork);
    }
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Injection bouton 7TV dans la barre de saisie Twitch
//
// Stratégie: hook sur NSObject.didMoveToWindow.
// Dès qu'une vue "Twitch.ChatInputView" apparaît dans la hiérarchie,
// on cherche le ChatInputViewEmoticonButton pour se positionner
// juste à sa gauche, et on injecte notre bouton violet.
//
// kS7TVTextFieldTagged posé sur ChatInputView (guard anti-doublon)
// ET sur le bouton (pour retrouver la ChatInputView au tap).
// ────────────────────────────────────────────────────────────

static const char kS7TVTextFieldTagged = 5;

@interface UIView (S7TVChatInputHook)
- (void)s7tv_didMoveToWindow;
@end

@implementation UIView (S7TVChatInputHook)

- (void)s7tv_didMoveToWindow {
    [self s7tv_didMoveToWindow]; // appel original

    // Filtrer : seule Twitch.ChatInputView nous intéresse
    if (![NSStringFromClass([self class]) isEqualToString:@"Twitch.ChatInputView"]) return;
    UIView *chatInputView = self;

    // Guard anti-doublon : on ne touche cette vue qu'une seule fois
    if (objc_getAssociatedObject(chatInputView, &kS7TVTextFieldTagged)) return;
    objc_setAssociatedObject(chatInputView, &kS7TVTextFieldTagged, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Attendre que le layout soit finalisé avant de chercher les sous-vues
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{

        // ── 1. Chercher ChatInputViewEmoticonButton RÉCURSIVEMENT ─────────────
        // On ne peut pas compter sur les frames au moment de didMoveToWindow
        // (layout pas encore finalisé). On cherche par nom de classe dans
        // toute la hiérarchie de chatInputView.
        __block UIView *emoticonBtn = nil;
        NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithArray:chatInputView.subviews];
        while (bfs.count > 0 && !emoticonBtn) {
            UIView *v = bfs.firstObject; [bfs removeObjectAtIndex:0];
            NSString *cn = NSStringFromClass([v class]);
            if ([cn containsString:@"Emoticon"] || [cn containsString:@"emoticon"]) {
                emoticonBtn = v;
            } else {
                [bfs addObjectsFromArray:v.subviews];
            }
        }

        // ── 2. Le container est le superview direct de l'emoticonBtn ─────────
        // D'après les logs : UIView frame=(60,8,274,40) dans ChatInputView
        UIView *target = emoticonBtn.superview ?: chatInputView;

        // Vérifier qu'on n'a pas déjà le bouton (protection re-entrante)
        for (UIView *sub in target.subviews) {
            if (sub.tag == 0x7777) return;
        }

        // ── 3. Créer le bouton 7TV ────────────────────────────────────────────
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = 0x7777;

        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
        UIImage *icon = [UIImage systemImageNamed:@"sparkles" withConfiguration:symCfg];
        if (icon) {
            [btn setImage:icon forState:UIControlStateNormal];
            btn.tintColor = [UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0];
        } else {
            [btn setTitle:@"7TV" forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor colorWithRed:0.55 green:0.25 blue:0.95 alpha:1.0]
                      forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        }

        // ── 4. Positionner à gauche du bouton emote Twitch ────────────────────
        CGFloat btnSize = 36.0;
        CGFloat btnX, btnY;

        if (emoticonBtn) {
            btnX = emoticonBtn.frame.origin.x - btnSize - 4.0;
            btnY = emoticonBtn.frame.origin.y
                 + (emoticonBtn.frame.size.height - btnSize) / 2.0;
        } else {
            btnX = MAX(0, target.frame.size.width - btnSize - 4.0);
            btnY = (target.frame.size.height - btnSize) / 2.0;
        }
        if (btnX < 0) btnX = 0;

        btn.frame = CGRectMake(btnX, btnY, btnSize, btnSize);
        btn.autoresizingMask = UIViewAutoresizingFlexibleRightMargin
                             | UIViewAutoresizingFlexibleTopMargin
                             | UIViewAutoresizingFlexibleBottomMargin;

        // Stocker la référence à chatInputView (pour l'insertion de texte)
        objc_setAssociatedObject(btn, &kS7TVTextFieldTagged, chatInputView,
                                 OBJC_ASSOCIATION_ASSIGN);

        [btn addTarget:[SevenTVManager sharedManager]
                action:@selector(s7tv_emoteButtonTappedForButton:)
      forControlEvents:UIControlEventTouchUpInside];

        [target addSubview:btn];
        [target bringSubviewToFront:btn];

        [[SevenTVManager sharedManager]
            log:@"🎹 Bouton 7TV injecté — target:%@ emoticonBtn:%@ x=%.0f y=%.0f",
            NSStringFromClass([target class]),
            emoticonBtn ? NSStringFromClass([emoticonBtn class]) : @"(introuvable)",
            btnX, btnY];
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
    UIView *chatInputView = objc_getAssociatedObject(sender, &kS7TVTextFieldTagged);
    [self toggleEmotePickerForChatInputView:chatInputView];
}

@end


// ────────────────────────────────────────────────────────────
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
                if (data && !error)
                    [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:data];
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
// MARK: - Extraction des emote IDs 7TV depuis un message IRC modifié
// ────────────────────────────────────────────────────────────

static NSArray<NSString *> *s7tv_extractEmoteIDs(NSString *ircMessage) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSRange tagRange = [ircMessage rangeOfString:@"emotes="];
    if (tagRange.location == NSNotFound) return result;

    NSString *afterTag = [ircMessage substringFromIndex:tagRange.location + 7];
    NSRange endRange = [afterTag rangeOfCharacterFromSet:
                        [NSCharacterSet characterSetWithCharactersInString:@" ;"]];
    NSString *emotesValue = (endRange.location != NSNotFound)
        ? [afterTag substringToIndex:endRange.location] : afterTag;
    if (emotesValue.length == 0) return result;

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *entry in [emotesValue componentsSeparatedByString:@"/"]) {
        NSString *idPart = [entry componentsSeparatedByString:@":"].firstObject ?: entry;
        if ([idPart hasPrefix:@"7tv_"]) {
            NSString *emoteID = [idPart substringFromIndex:4];
            if (emoteID.length > 0 && ![seen containsObject:emoteID]) {
                [seen addObject:emoteID];
                [result addObject:emoteID];
            }
        }
    }
    return result;
}


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
    }
}


// ────────────────────────────────────────────────────────────
// MARK: - Scroll chat vers le bas après livraison d'un message
// ────────────────────────────────────────────────────────────

static void s7tv_scrollChatToBottom(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    if (!keyWindow) return;

    UIScrollView *chatView = nil;
    CGFloat bestArea = 0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:keyWindow];
    while (queue.count > 0) {
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UIScrollView class]] && !v.isHidden && v.alpha > 0.01) {
            UIScrollView *sv = (UIScrollView *)v;
            CGFloat area    = sv.bounds.size.width * sv.bounds.size.height;
            CGFloat overflow = sv.contentSize.height - sv.bounds.size.height;
            if (area > bestArea && overflow > 100) { bestArea = area; chatView = sv; }
        }
        for (UIView *sub in v.subviews) if (!sub.isHidden) [queue addObject:sub];
    }
    if (!chatView) return;

    CGFloat maxY     = chatView.contentSize.height - chatView.bounds.size.height;
    CGFloat currentY = chatView.contentOffset.y;
    if (maxY <= 0) return;

    if (maxY - currentY <= 200.0) {
        [chatView setContentOffset:CGPointMake(chatView.contentOffset.x, maxY)
                          animated:NO];
    }
}


// ────────────────────────────────────────────────────────────
// MARK: - Reload les UITextView/UILabel visibles dans le chat
// ────────────────────────────────────────────────────────────

static void s7tv_reloadVisibleChatCells(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    if (!keyWindow) return;

    UIScrollView *chatView = nil;
    CGFloat bestArea = 0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:keyWindow];
    while (queue.count > 0) {
        UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UIScrollView class]] && !v.isHidden && v.alpha > 0.01) {
            UIScrollView *sv = (UIScrollView *)v;
            CGFloat area    = sv.bounds.size.width * sv.bounds.size.height;
            CGFloat overflow = sv.contentSize.height - sv.bounds.size.height;
            if (area > bestArea && overflow > 100) { bestArea = area; chatView = sv; }
        }
        for (UIView *sub in v.subviews) if (!sub.isHidden) [queue addObject:sub];
    }
    if (!chatView) return;

    NSInteger reloaded = 0;
    NSMutableArray<UIView *> *bfs = [NSMutableArray arrayWithArray:chatView.subviews];
    while (bfs.count > 0) {
        UIView *v = bfs.firstObject; [bfs removeObjectAtIndex:0];

        if ([v isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)v;
            if (!objc_getAssociatedObject(tv, &kS7TVReloadGuard)) {
                objc_setAssociatedObject(tv, &kS7TVReloadGuard, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSAttributedString *saved = tv.attributedText;
                if (saved.length > 0) { tv.attributedText = nil; tv.attributedText = saved; reloaded++; }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    objc_setAssociatedObject(tv, &kS7TVReloadGuard, nil,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                });
            }
            continue;
        }

        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            if (!objc_getAssociatedObject(lbl, &kS7TVReloadGuard)) {
                objc_setAssociatedObject(lbl, &kS7TVReloadGuard, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                NSAttributedString *saved = lbl.attributedText;
                if (saved.length > 0) { lbl.attributedText = nil; lbl.attributedText = saved; reloaded++; }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    objc_setAssociatedObject(lbl, &kS7TVReloadGuard, nil,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                });
            }
            continue;
        }

        for (UIView *sub in v.subviews) if (!sub.isHidden) [bfs addObject:sub];
    }
    [[SevenTVManager sharedManager] log:@"♻️ Reload %ld cellule(s) visibles", (long)reloaded];
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

                    if (modified && ![modified isEqualToString:textToProcess]) {

                        completionHandler(
                            [[NSURLSessionWebSocketMessage alloc] initWithString:modified],
                            nil
                        );

                        NSArray<NSString *> *emoteIDs = s7tv_extractEmoteIDs(modified);
                        NSMutableArray<NSString *> *uncached = [NSMutableArray array];
                        for (NSString *eid in emoteIDs) {
                            if (![SevenTVURLProtocol isEmoteIDCached:eid]) [uncached addObject:eid];
                        }

                        if (uncached.count > 0) {
                            [[SevenTVManager sharedManager]
                                log:@"🔄 Prefetch background — %lu emote(s): %@",
                                (unsigned long)uncached.count,
                                [uncached componentsJoinedByString:@", "]];

                            dispatch_group_t group = dispatch_group_create();
                            for (NSString *eid in uncached) {
                                dispatch_group_enter(group);
                                [SevenTVURLProtocol prefetchEmoteID:eid completion:^{
                                    dispatch_group_leave(group);
                                }];
                            }
                            dispatch_group_notify(group, dispatch_get_main_queue(), ^{
                                [[SevenTVManager sharedManager]
                                    log:@"✅ Images prêtes → reload cellules visibles"];
                                s7tv_reloadVisibleChatCells();
                            });
                        }
                        return;
                    }

                    if (message.type == NSURLSessionWebSocketMessageTypeData && textToProcess) {
                        completionHandler(
                            [[NSURLSessionWebSocketMessage alloc] initWithString:textToProcess],
                            nil
                        );
                        return;
                    }
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
// MARK: - Swizzle NSTextAttachment (setImage: + image getter)
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle_attachment(void) {
    Class cls = [NSTextAttachment class];

    // setter : setImage:
    s7tv_swizzle(cls, cls,
                 @selector(setImage:),
                 @selector(s7tv_setAttachImage:));

    // getter : image
    // On doit swizzler la méthode d'instance du getter de la propriété "image"
    s7tv_swizzle(cls, cls,
                 @selector(image),
                 @selector(s7tv_getAttachImage));
}



// ────────────────────────────────────────────────────────────
// MARK: - Tap Logger — log la hiérarchie au point touché
//
// À chaque tap dans l'app, on logue :
//   • Les coordonnées du tap
//   • La vue "hit" (hitTest)
//   • Toute la chaîne de superviews avec leur classe + frame
//
// Désactivé automatiquement après 30 taps pour ne pas polluer
// les logs une fois le diagnostic terminé.
// Peut être réactivé en touchant l'écran 5x rapidement (TODO).
// ────────────────────────────────────────────────────────────

static NSInteger s_tapLogCount = 0;
static const NSInteger kTapLogMax = 30;

@interface UIWindow (S7TVTapLogger)
- (void)s7tv_sendEvent:(UIEvent *)event;
@end

@implementation UIWindow (S7TVTapLogger)

- (void)s7tv_sendEvent:(UIEvent *)event {
    [self s7tv_sendEvent:event];

    if (s_tapLogCount >= kTapLogMax) return;
    if (event.type != UIEventTypeTouches) return;

    UITouch *touch = event.allTouches.anyObject;
    if (!touch || touch.phase != UITouchPhaseBegan) return;

    s_tapLogCount++;
    CGPoint pt = [touch locationInView:self];

    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr log:@"👆 TAP #%ld @ (%.0f, %.0f) — hiérarchie:",
     (long)s_tapLogCount, pt.x, pt.y];

    // Vue touchée
    UIView *hit = [self hitTest:pt withEvent:nil];
    [mgr log:@"  HIT: %@ frame=(%.0f,%.0f,%.0f,%.0f) tag=%ld ph='%@'",
     NSStringFromClass([hit class]),
     hit.frame.origin.x, hit.frame.origin.y, hit.frame.size.width, hit.frame.size.height,
     (long)hit.tag,
     ([hit isKindOfClass:[UITextField class]] ? ((UITextField *)hit).placeholder : @"")];

    // Chaîne de superviews (max 12 niveaux)
    UIView *v = hit.superview;
    for (int d = 1; d <= 12 && v; d++, v = v.superview) {
        NSString *extra = @"";
        if ([v isKindOfClass:[UITextField class]])
            extra = [NSString stringWithFormat:@" ph='%@'", ((UITextField *)v).placeholder ?: @""];
        [mgr log:@"  [%d] %@ frame=(%.0f,%.0f,%.0f,%.0f)%@",
         d, NSStringFromClass([v class]),
         v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height,
         extra];
    }

    if (s_tapLogCount == kTapLogMax) {
        [mgr log:@"👆 Tap logger désactivé après %ld taps — ouvre les logs pour analyser",
         (long)kTapLogMax];
    }
}

@end

// ────────────────────────────────────────────────────────────
// MARK: - Point d'entrée __attribute__((constructor))
// ────────────────────────────────────────────────────────────

__attribute__((constructor))
static void TwitchSevenTVInit(void) {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr log:@"🔌 Chargement TwitchSevenTV v2.0 (substrate-free)..."];

    // ── Swizzle UIWindow sendEvent: (tap logger diagnostic) ─────────────────────
    s7tv_swizzle([UIWindow class],
                 [UIWindow class],
                 @selector(sendEvent:),
                 @selector(s7tv_sendEvent:));

    // ── Swizzle UIView didMoveToWindow (injection bouton dans ChatInputView) ──
    s7tv_swizzle([UIView class],
                 [UIView class],
                 @selector(didMoveToWindow),
                 @selector(s7tv_didMoveToWindow));

    // ── Swizzle UIImage imageWithData: (décodage WebP/GIF + tag) ──────────────
    s7tv_swizzle(object_getClass([UIImage class]),
                 object_getClass([UIImage class]),
                 @selector(imageWithData:),
                 @selector(s7tv_imageWithData:));

    // ── Swizzle UIImageView setImage: (animation + resize, 7TV seulement) ─────
    s7tv_swizzle([UIImageView class],
                 [UIImageView class],
                 @selector(setImage:),
                 @selector(s7tv_setImage:));

    // ── Swizzle NSTextAttachment (animation CoreText path) ────────────────────
    s7tv_swizzle_attachment();

    // ── Fix B: protocolClasses swizzle (avant la création de sessions) ────────
    s7tv_swizzle_protocol_classes();

    // ── Swizzle NSURLSession (réponses GQL Twitch) ────────────────────────────
    s7tv_swizzle_session();

    // ── Swizzle NSURLSessionWebSocketTask (chat IRC) ──────────────────────────
    s7tv_swizzle_websocket();

    // ── Setup sur le main thread ──────────────────────────────────────────────
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SevenTVManager sharedManager] setup];
        [NSURLProtocol registerClass:[SevenTVURLProtocol class]];
        [[SevenTVManager sharedManager] log:@"✅ SevenTVManager prêt, URLProtocol enregistré"];

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [[SevenTVManager sharedManager] addSettingsButton];
                [[SevenTVManager sharedManager] log:@"✅ Bouton 7TV ajouté"];
            }
        );
    });
}
