/*
 * TweakSevenTV.m  —  Substrate-FREE version
 *
 * CORRECTIFS v1.2:
 *   Fix A — ROOMSTATE: extraire le room-id directement depuis IRC
 *            (plus fiable que le hook GQL). Twitch envoie ROOMSTATE
 *            immédiatement après JOIN avec room-id=XXXXX.
 *
 *   Fix B — URLProtocol: swizzler protocolClasses sur
 *            NSURLSessionConfiguration pour que SevenTVURLProtocol
 *            intercepte les requêtes de TOUTES les sessions Twitch,
 *            y compris celles avec une config custom.
 */

#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"


// ────────────────────────────────────────────────────────────
// MARK: - Fix animations GIF
//
// `UIImage imageWithData:` retourne un UIImage statique (1ère frame) même
// pour un GIF multi-frames. On swizzle cette méthode pour décoder toutes les
// frames via CGImageSource et retourner un UIImage animé.
// On swizzle aussi UIImageView.setImage: pour démarrer l'animation quand
// l'image a des frames (UIImage.animationImages non-vide).
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

    // Détecter GIF (47 49 46 38 = "GIF8") ou WebP (52 49 46 46 = "RIFF" + offset 8: "57 45 42 50" = "WEBP")
    BOOL isGIF  = (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38);
    BOOL isWebP = (data.length >= 12 &&
                   b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
                   b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50);

    if (isGIF || isWebP) {
        CGImageSourceRef src =
            CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (src) {
            size_t count = CGImageSourceGetCount(src);

            if (count > 1) {
                // ── Image animée (multi-frames) ───────────────────────────
                NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:count];
                NSTimeInterval totalDuration = 0;

                for (size_t i = 0; i < count; i++) {
                    CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, i, NULL);
                    if (cgImg) {
                        // Upscale: les emotes 7TV en 4x WebP font ~112px, les emotes
                        // Twitch natives affichées dans le chat font ~56pt @2x = 112px.
                        // On target 56pt = taille d'une emote Twitch standard dans le chat.
                        // Si l'image est plus petite on la scale up via UIGraphicsImageRenderer.
                        UIImage *frame = [UIImage imageWithCGImage:cgImg
                                                             scale:1.0
                                                       orientation:UIImageOrientationUp];
                        [frames addObject:frame];
                        CFRelease(cgImg);
                    }

                    // Durée de la frame
                    NSDictionary *props = (__bridge_transfer NSDictionary *)
                        CGImageSourceCopyPropertiesAtIndex(src, i, NULL);
                    NSDictionary *gifDict  = props[(__bridge NSString *)kCGImagePropertyGIFDictionary];
                    NSDictionary *webpDict = props[(__bridge NSString *)kCGImagePropertyWebPDictionary];
                    NSDictionary *animDict = gifDict ?: webpDict;

                    NSNumber *delay =
                        animDict[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime]
                        ?: animDict[(__bridge NSString *)kCGImagePropertyGIFDelayTime];
                    totalDuration += MAX(delay.doubleValue, 0.01);
                }
                CFRelease(src);

                if (frames.count > 1) {
                    return [UIImage animatedImageWithImages:frames
                                                  duration:totalDuration];
                }
                if (frames.count == 1) return frames[0];

            } else if (count == 1) {
                // ── Image statique ────────────────────────────────────────
                CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
                CFRelease(src);
                if (cgImg) {
                    UIImage *img = [UIImage imageWithCGImage:cgImg
                                                      scale:1.0
                                                orientation:UIImageOrientationUp];
                    CFRelease(cgImg);
                    return img;
                }
            } else {
                CFRelease(src);
            }
        }
    }

    // Fallback: appel de l'original
    return [self s7tv_imageWithData:data];
}

@end


@interface UIImageView (SevenTVAnimation)
- (void)s7tv_setImage:(UIImage *)image;
@end

@implementation UIImageView (SevenTVAnimation)

- (void)s7tv_setImage:(UIImage *)image {
    [self s7tv_setImage:image]; // appelle l'original (swizzlé)

    if (!image) return;

    // ── Emotes animées ────────────────────────────────────────────────────────
    if (image.images.count > 1) {
        self.animationImages      = image.images;
        self.animationDuration    = image.duration > 0 ? image.duration : 1.0;
        self.animationRepeatCount = 0; // infini
        [self startAnimating];
    }

    // ── Fix taille + rendu emotes rectangulaires ──────────────────────────────
    //
    // Twitch rend le chat via CoreText/NSTextAttachment. Le layout texte est
    // calculé UNE fois puis mis en cache. Quand setImage: est appelé sur
    // l'UIImageView de l'emote, CoreText ne sait pas que l'image a changé →
    // la cellule ne se redessine pas → emote invisible jusqu'au prochain
    // scroll qui force un re-render complet.
    //
    // Fix : après avoir mis à jour contrainte/frame, appeler setNeedsDisplay
    // sur toute la hiérarchie jusqu'à la cellule (profondeur 8 max).
    // On fait ça SYNCHRONE et sur le main thread pour éviter que la cellule
    // soit recyclée avant l'update (problème avec dispatch_async).

    CGFloat imgW = image.size.width;
    CGFloat imgH = image.size.height;
    if (imgH <= 0 || imgW <= 0) return;

    CGFloat ratio = imgW / imgH;

    NSString *superviewClass = NSStringFromClass([self.superview class]);
    if ([superviewClass containsString:@"TabBar"] ||
        [superviewClass containsString:@"NavigationBar"] ||
        [superviewClass containsString:@"ToolBar"]) return;

    CGFloat viewH = self.bounds.size.height > 0
        ? self.bounds.size.height
        : self.frame.size.height;
    if (viewH < 10 || viewH > 80.0) return;

    void (^applyFix)(void) = ^{
        CGFloat h = self.bounds.size.height > 0
            ? self.bounds.size.height
            : self.frame.size.height;
        if (h < 1) h = viewH; // fallback sur la valeur capturée

        // ── Ajustement de la largeur pour emotes rectangulaires ──────────────
        if (ratio >= 1.15) {
            CGFloat targetW = ceilf(h * ratio);

            BOOL found = NO;
            for (NSLayoutConstraint *c in self.constraints) {
                if (c.firstAttribute == NSLayoutAttributeWidth && c.secondItem == nil) {
                    c.constant = targetW; found = YES; break;
                }
            }
            if (!found) {
                for (NSLayoutConstraint *c in self.superview.constraints) {
                    if ((c.firstItem == self || c.secondItem == self) &&
                        (c.firstAttribute  == NSLayoutAttributeWidth ||
                         c.secondAttribute == NSLayoutAttributeWidth) &&
                        c.secondItem == nil) {
                        c.constant = targetW; found = YES; break;
                    }
                }
            }
            if (!found) {
                CGRect f = self.frame; f.size.width = targetW; self.frame = f;
            }
            self.contentMode = UIViewContentModeScaleAspectFit;
        }

        // ── Force re-render CoreText sur toute la hiérarchie ─────────────────
        // Sans ça, la cellule reste figée sur son layout initial (emote vide)
        // jusqu'au prochain scroll qui force un re-render complet.
        UIView *v = self;
        for (int depth = 0; depth < 8; depth++) {
            [v setNeedsDisplay];
            if ([v isKindOfClass:[UITableViewCell class]] ||
                [v isKindOfClass:[UICollectionViewCell class]]) {
                [v setNeedsLayout];
                break; // on s'arrête à la cellule, pas besoin de remonter plus haut
            }
            if (!v.superview) break;
            v = v.superview;
        }
    };

    if ([NSThread isMainThread]) {
        applyFix();
    } else {
        dispatch_async(dispatch_get_main_queue(), applyFix);
    }
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Helper swizzling
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
//
// [NSURLProtocol registerClass:] ne couvre que les sessions
// utilisant la configuration par défaut du système.
// Twitch crée ses propres sessions avec des configs custom →
// notre URLProtocol est ignoré par défaut.
//
// Solution: swizzler protocolClasses pour injecter
// SevenTVURLProtocol dans toutes les configurations.
// ────────────────────────────────────────────────────────────

@interface NSURLSessionConfiguration (SevenTV)
- (NSArray *)s7tv_protocolClasses;
@end

@implementation NSURLSessionConfiguration (SevenTV)

- (NSArray *)s7tv_protocolClasses {
    NSArray *original = [self s7tv_protocolClasses]; // appelle l'original après swizzle
    Class ourClass = [SevenTVURLProtocol class];

    if (![original containsObject:ourClass]) {
        // Mettre notre protocole EN PREMIER pour avoir la priorité
        NSMutableArray *arr = [NSMutableArray arrayWithObject:ourClass];
        if (original.count > 0) {
            [arr addObjectsFromArray:original];
        }
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
    NSString *host = request.URL.host ?: @"";

    if ([host isEqualToString:@"gql.twitch.tv"] && completionHandler) {
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (data && !error) {
                    [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:data];
                }
                completionHandler(data, response, error);
            };
        return [self s7tv_dataTaskWithRequest:request completionHandler:wrappedHandler];
    }

    return [self s7tv_dataTaskWithRequest:request completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)s7tv_dataTaskWithURL:(NSURL *)url
                             completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *host = url.host ?: @"";

    if ([host isEqualToString:@"gql.twitch.tv"] && completionHandler) {
        void (^wrappedHandler)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (data && !error) {
                    [[SevenTVManager sharedManager] extractAndLoadEmotesFromGQLResponse:data];
                }
                completionHandler(data, response, error);
            };
        return [self s7tv_dataTaskWithURL:url completionHandler:wrappedHandler];
    }

    return [self s7tv_dataTaskWithURL:url completionHandler:completionHandler];
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Hook NSURLSessionWebSocketTask (chat IRC Twitch)
// ────────────────────────────────────────────────────────────

// ── Extraction des emote IDs 7TV depuis un message IRC modifié ───────────────
//
// Exemple de tag injecté: "emotes=7tv_01FA35:10-17,7tv_01FB22:20-25"
// Retourne: @[@"01FA35", @"01FB22"] (sans le préfixe "7tv_")
//
// On déduplique car une même emote peut apparaître plusieurs fois dans
// le même message (ex: "KEKW KEKW KEKW" → un seul ID à préfetch).
static NSArray<NSString *> *s7tv_extractEmoteIDs(NSString *ircMessage) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];

    NSRange tagRange = [ircMessage rangeOfString:@"emotes="];
    if (tagRange.location == NSNotFound) return result;

    // Isoler la valeur du tag "emotes=" (jusqu'au prochain espace ou ";")
    NSString *afterTag = [ircMessage substringFromIndex:tagRange.location + 7];
    NSRange endRange = [afterTag rangeOfCharacterFromSet:
                        [NSCharacterSet characterSetWithCharactersInString:@" ;"]];
    NSString *emotesValue = (endRange.location != NSNotFound)
        ? [afterTag substringToIndex:endRange.location]
        : afterTag;

    if (emotesValue.length == 0) return result;

    // Format: "7tv_ID1:0-5/7tv_ID1:8-12,7tv_ID2:20-25"
    // Séparateur entre emotes différentes: ","
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *entry in [emotesValue componentsSeparatedByString:@","]) {
        // Prendre seulement la partie avant ":" (= "7tv_ID")
        NSString *idPart = [entry componentsSeparatedByString:@":"].firstObject ?: entry;
        if ([idPart hasPrefix:@"7tv_"]) {
            NSString *emoteID = [idPart substringFromIndex:4]; // retirer "7tv_"
            if (emoteID.length > 0 && ![seen containsObject:emoteID]) {
                [seen addObject:emoteID];
                [result addObject:emoteID];
            }
        }
    }
    return result;
}


// ── Fix A: fonction C statique pour éviter le crash "unrecognized selector" ──
// s7tv_handleRoomState: ne peut PAS être une méthode ObjC sur la catégorie car
// après swizzle, self est __NSURLSessionWebSocketTask (classe concrète) qui ne
// trouve pas les méthodes de la catégorie abstraite via dispatch ObjC.
// Une fonction C statique est appelée directement, sans lookup → pas de crash.
static void s7tv_handleRoomState(NSString *ircMessage) {
    NSRange roomIDRange = [ircMessage rangeOfString:@"room-id="];
    if (roomIDRange.location == NSNotFound) return;

    NSString *afterRoomID = [ircMessage substringFromIndex:roomIDRange.location + 8];

    // L'ID se termine au prochain ";", espace, ou fin de ligne
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
        [mgr loadEmotesForChannelTwitchID:roomID];
    }
}


// ── Scroll le chat vers le bas après livraison d'un message retenu ──────────
//
// Pendant la hold (~500ms), d'autres messages arrivent et Twitch auto-scrolle
// pour eux. Notre message est livré APRÈS : il est ajouté en bas de la liste
// mais Twitch ne scrolle plus → cellule hors écran → image jamais demandée.
//
// On cherche le plus grand UIScrollView visible (= le chat) et on scrolle
// en bas, MAIS seulement si l'utilisateur était déjà proche du bas (< 200pt).
// Si l'utilisateur a scrollé vers le haut pour lire, on ne le dérange pas.
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

    // BFS : trouver le plus grand UIScrollView avec contenu qui déborde (= le chat)
    UIScrollView *chatView  = nil;
    CGFloat       bestArea  = 0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:keyWindow];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UIScrollView class]] && !v.isHidden && v.alpha > 0.01) {
            UIScrollView *sv  = (UIScrollView *)v;
            CGFloat area      = sv.bounds.size.width * sv.bounds.size.height;
            CGFloat overflow  = sv.contentSize.height - sv.bounds.size.height;
            if (area > bestArea && overflow > 100) {
                bestArea = area;
                chatView = sv;
            }
        }
        for (UIView *sub in v.subviews) {
            if (!sub.isHidden) [queue addObject:sub];
        }
    }
    if (!chatView) return;

    CGFloat maxY     = chatView.contentSize.height - chatView.bounds.size.height;
    CGFloat currentY = chatView.contentOffset.y;
    if (maxY <= 0) return;

    // Seulement si on était déjà proche du bas (≤ 200pt d'écart)
    if (maxY - currentY <= 200.0) {
        [chatView setContentOffset:CGPointMake(chatView.contentOffset.x, maxY)
                          animated:NO];
        [[SevenTVManager sharedManager] log:@"📜 Scroll chat → bas (delta=%.0f)", maxY - currentY];
    }
}


@interface NSURLSessionWebSocketTask (SevenTV)
- (void)s7tv_receiveMessageWithCompletionHandler:
    (void (^)(NSURLSessionWebSocketMessage *, NSError *))completionHandler;
- (void)s7tv_sendMessage:(NSURLSessionWebSocketMessage *)message
       completionHandler:(void (^)(NSError *))completionHandler;
@end

@implementation NSURLSessionWebSocketTask (SevenTV)

// Messages ENTRANTS : extraire room-id depuis ROOMSTATE + injecter emotes dans PRIVMSG
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
                    if (textToProcess) {
                        [[SevenTVManager sharedManager]
                            log:@"ℹ️  Frame TypeData convertie en texte (%lu octets)",
                            (unsigned long)message.data.length];
                    } else {
                        [[SevenTVManager sharedManager]
                            log:@"⚠️  Frame TypeData non-UTF8 ignorée (%lu octets)",
                            (unsigned long)message.data.length];
                    }
                }

                if (textToProcess) {

                    // ── Fix A: appel direct en C, pas de dispatch ObjC ───
                    if ([textToProcess containsString:@"ROOMSTATE"]) {
                        s7tv_handleRoomState(textToProcess);
                    }

                    // ── Injection des emotes 7TV dans PRIVMSG ────────────
                    NSString *modified = [[SevenTVManager sharedManager]
                                          injectSevenTVEmotesIntoIRCMessage:textToProcess];

                    if (modified && ![modified isEqualToString:textToProcess]) {

                        // Extraire les IDs des emotes injectées dans ce message
                        NSArray<NSString *> *emoteIDs = s7tv_extractEmoteIDs(modified);

                        // Filtrer celles qui ne sont pas encore en cache
                        NSMutableArray<NSString *> *uncached = [NSMutableArray array];
                        for (NSString *eid in emoteIDs) {
                            if (![SevenTVURLProtocol isEmoteIDCached:eid]) {
                                [uncached addObject:eid];
                            }
                        }

                        // Bloc qui livre le message modifié à Twitch
                        NSString *finalText = modified;
                        void (^deliver)(void) = ^{
                            NSURLSessionWebSocketMessage *newMsg =
                                [[NSURLSessionWebSocketMessage alloc] initWithString:finalText];
                            completionHandler(newMsg, nil);
                            // Scroll chat en bas après livraison d'un message retenu :
                            // si d'autres messages sont arrivés pendant la hold, notre
                            // cellule risque d'être hors écran → l'emote ne se charge pas.
                            dispatch_after(
                                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                                dispatch_get_main_queue(),
                                ^{ s7tv_scrollChatToBottom(); }
                            );
                        };

                        if (uncached.count == 0) {
                            // Tout en cache → livraison immédiate, zéro délai
                            deliver();
                        } else {
                            // Préfetch des images manquantes, PUIS livraison.
                            // Le message n'est pas encore visible dans le chat Twitch.
                            // Quand toutes les images sont en cache (~200ms), on le livre.
                            // Twitch rend la cellule → demande les images → cache chaud → instantané.
                            [[SevenTVManager sharedManager]
                                log:@"⏳ Hold message — %lu emote(s) à préfetch: %@",
                                (unsigned long)uncached.count,
                                [uncached componentsJoinedByString:@", "]];

                            dispatch_group_t group = dispatch_group_create();
                            for (NSString *eid in uncached) {
                                dispatch_group_enter(group);
                                [SevenTVURLProtocol prefetchEmoteID:eid completion:^{
                                    dispatch_group_leave(group);
                                }];
                            }
                            // Livrer sur un thread background — pas besoin du main thread ici,
                            // completionHandler est appelé sur le thread de la session WebSocket.
                            dispatch_group_notify(group,
                                                  dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                                                  deliver);
                        }
                        return;
                    }

                    // Frame TypeData convertie → renvoyer en String
                    if (message.type == NSURLSessionWebSocketMessageTypeData && textToProcess) {
                        NSURLSessionWebSocketMessage *asText =
                            [[NSURLSessionWebSocketMessage alloc] initWithString:textToProcess];
                        completionHandler(asText, nil);
                        return;
                    }
                }
            }
            completionHandler(message, error);
        };

    [self s7tv_receiveMessageWithCompletionHandler:wrappedHandler];
}

// Messages SORTANTS : détecter "JOIN #channel"
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
    // Obtenir la classe concrète via une instance sonde
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
        [[SevenTVManager sharedManager] log:@"⚠️  NSURLSessionWebSocketTask introuvable (iOS < 13?)"];
        return;
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *probeSession = [NSURLSession sessionWithConfiguration:cfg];
    NSURL *probeURL = [NSURL URLWithString:@"wss://irc-ws.chat.twitch.tv/irc"];

    NSURLSessionWebSocketTask *probeTask = [probeSession webSocketTaskWithURL:probeURL];
    Class realWSClass = object_getClass(probeTask);
    [probeTask cancel];

    [[SevenTVManager sharedManager] log:@"🔍 NSURLSessionWebSocketTask classe concrète: %@",
     NSStringFromClass(realWSClass)];

    if (realWSClass != wsAbstractClass) {
        [[SevenTVManager sharedManager] log:@"ℹ️  Classe abstraite: %@ → classe concrète: %@",
         NSStringFromClass(wsAbstractClass), NSStringFromClass(realWSClass)];
    }

    s7tv_swizzle(realWSClass,
                 wsAbstractClass,
                 @selector(receiveMessageWithCompletionHandler:),
                 @selector(s7tv_receiveMessageWithCompletionHandler:));

    s7tv_swizzle(realWSClass,
                 wsAbstractClass,
                 @selector(sendMessage:completionHandler:),
                 @selector(s7tv_sendMessage:completionHandler:));
}


// ────────────────────────────────────────────────────────────
// MARK: - Point d'entrée
// ────────────────────────────────────────────────────────────

__attribute__((constructor))
static void TwitchSevenTVInit(void) {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr log:@"🔌 Chargement TwitchSevenTV v1.3 (substrate-free)..."];

    // ── Swizzle UIImage imageWithData: pour décoder les GIFs animés ──
    s7tv_swizzle(object_getClass([UIImage class]),   // meta-classe (méthode de classe)
                 object_getClass([UIImage class]),
                 @selector(imageWithData:),
                 @selector(s7tv_imageWithData:));

    // ── Swizzle UIImageView setImage: pour démarrer l'animation ──
    s7tv_swizzle([UIImageView class],
                 [UIImageView class],
                 @selector(setImage:),
                 @selector(s7tv_setImage:));

    // ── Fix B: protocolClasses swizzle (avant la création de sessions) ──
    s7tv_swizzle_protocol_classes();

    // ── Swizzle NSURLSession (réponses GQL Twitch) ──
    s7tv_swizzle_session();

    // ── Swizzle NSURLSessionWebSocketTask (chat IRC) ──
    s7tv_swizzle_websocket();

    // ── Initialiser le gestionnaire 7TV sur le main thread ──
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SevenTVManager sharedManager] setup];
        // registerClass reste utile pour les sessions "système" non swizzlées
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
