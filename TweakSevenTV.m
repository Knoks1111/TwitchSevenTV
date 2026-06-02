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
    // Vérifier si c'est un GIF (magic bytes: 47 49 46 38 = "GIF8")
    if (data.length >= 4) {
        const uint8_t *b = (const uint8_t *)data.bytes;
        if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) {
            CGImageSourceRef src =
                CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            if (src) {
                size_t count = CGImageSourceGetCount(src);
                if (count > 1) {
                    NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:count];
                    NSTimeInterval totalDuration = 0;

                    for (size_t i = 0; i < count; i++) {
                        CGImageRef cgImg =
                            CGImageSourceCreateImageAtIndex(src, i, NULL);
                        if (cgImg) {
                            [frames addObject:[UIImage imageWithCGImage:cgImg]];
                            CFRelease(cgImg);
                        }

                        // Durée de la frame (kCGImagePropertyGIFDictionary)
                        NSDictionary *props = (__bridge_transfer NSDictionary *)
                            CGImageSourceCopyPropertiesAtIndex(src, i, NULL);
                        NSDictionary *gif  = props[(__bridge NSString *)
                                                   kCGImagePropertyGIFDictionary];
                        NSNumber *delay =
                            gif[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime]
                            ?: gif[(__bridge NSString *)kCGImagePropertyGIFDelayTime];
                        // Minimum 10ms pour éviter les GIFs trop rapides
                        totalDuration += MAX(delay.doubleValue, 0.01);
                    }
                    CFRelease(src);

                    if (frames.count > 1) {
                        return [UIImage animatedImageWithImages:frames
                                                      duration:totalDuration];
                    }
                    if (frames.count == 1) return frames[0];
                }
                if (src) CFRelease(src);
            }
        }
    }
    // Fallback: appel de l'original (swizzlé → s7tv_ appelle l'original)
    return [self s7tv_imageWithData:data];
}

@end


@interface UIImageView (SevenTVAnimation)
- (void)s7tv_setImage:(UIImage *)image;
@end

@implementation UIImageView (SevenTVAnimation)

- (void)s7tv_setImage:(UIImage *)image {
    [self s7tv_setImage:image]; // appelle l'original (swizzlé)

    // Si l'image a des frames animées, démarrer l'animation
    if (image.images.count > 1) {
        self.animationImages   = image.images;
        self.animationDuration = image.duration > 0 ? image.duration : 1.0;
        self.animationRepeatCount = 0; // infini
        [self startAnimating];
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
                        NSURLSessionWebSocketMessage *newMsg =
                            [[NSURLSessionWebSocketMessage alloc] initWithString:modified];
                        completionHandler(newMsg, nil);
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
