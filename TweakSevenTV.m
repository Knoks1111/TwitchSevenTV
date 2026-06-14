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
#import <ImageIO/ImageIO.h>
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVLogo.h"
#import "SevenTVSettingsController.h"
#import "SevenTVAdBlock.h"




// ────────────────────────────────────────────────────────────
// MARK: - Clés associated objects
// ────────────────────────────────────────────────────────────

static const char kS7TVTextFieldTagged = 5;
static const char kS7TVBitsHijacked    = 6;
static const char kS7TVOrigSectionCount = 7;


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

// ── Wrapper pour annuler un dispatch_source_t via associated object ──────────
// Quand le layer est recyclé, le associated object est relâché → dealloc → cancel.
@interface S7TVTimerWrapper : NSObject
- (instancetype)initWithTimer:(dispatch_source_t)timer;
@end
@implementation S7TVTimerWrapper {
    dispatch_source_t _timer;
}
- (instancetype)initWithTimer:(dispatch_source_t)t {
    self = [super init];
    if (self) _timer = t;
    return self;
}
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
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
// MARK: - Hijack du bouton Bits → bouton 7TV
// ────────────────────────────────────────────────────────────

@interface UIView (S7TVChatInputHook)
- (void)s7tv_didMoveToWindow;
@end

@implementation UIView (S7TVChatInputHook)

- (void)s7tv_didMoveToWindow {
    [self s7tv_didMoveToWindow]; // appel original

    NSString *selfClass = NSStringFromClass([self class]);

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
    Class nic = NSClassFromString(@"TwitchKit.NetworkImageRequester");
    if (!nic) {
        [[SevenTVManager sharedManager] log:@"⚠️ NetworkImageRequester introuvable"];
        return;
    }

    SevenTVManager *mgr = [SevenTVManager sharedManager];

    // ── variante courte : imageAtURL:withScale:persistingFor: ──
    SEL selImg1 = NSSelectorFromString(@"imageAtURL:withScale:persistingFor:");
    Method mImg1 = class_getInstanceMethod(nic, selImg1);
    if (mImg1) {
        IMP orig = method_getImplementation(mImg1);
        method_setImplementation(mImg1, imp_implementationWithBlock(
            ^id(id self_, NSURL *url, CGFloat scale, id persist) {
                [mgr log:@"🖼A %@  scale=%.1f", url.absoluteString, scale];
                return ((id(*)(id,SEL,NSURL*,CGFloat,id))orig)(self_, selImg1, url, scale, persist);
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
                [mgr log:@"🖼B %@  scale=%.1f mem=%d user=%d", url.absoluteString, scale, mem, user];
                return ((id(*)(id,SEL,NSURL*,CGFloat,id,BOOL,BOOL))orig)(self_, selImg2, url, scale, persist, mem, user);
            }));
        [mgr log:@"✅ Hook imageAtURL:...:storeInMemoryCache:userInitiated: OK"];
    }

    // ── variante courte : animatedImageAtURL:withStaticScale:persistingFor: ──
    SEL selAnim1 = NSSelectorFromString(@"animatedImageAtURL:withStaticScale:persistingFor:");
    Method mAnim1 = class_getInstanceMethod(nic, selAnim1);
    if (mAnim1) {
        IMP orig = method_getImplementation(mAnim1);
        method_setImplementation(mAnim1, imp_implementationWithBlock(
            ^id(id self_, NSURL *url, CGFloat scale, id persist) {
                [mgr log:@"🎞A %@  scale=%.1f", url.absoluteString, scale];
                return ((id(*)(id,SEL,NSURL*,CGFloat,id))orig)(self_, selAnim1, url, scale, persist);
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
                [mgr log:@"🎞B %@  scale=%.1f user=%d", url.absoluteString, scale, user];
                return ((id(*)(id,SEL,NSURL*,CGFloat,id,BOOL))orig)(self_, selAnim2, url, scale, persist, user);
            }));
        [mgr log:@"✅ Hook animatedImageAtURL:...:userInitiated: OK"];
    }
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

                // Attendre que le layout soit fini puis resizer
                __weak UITableViewCell *weakCell = cell;
                __weak UITableView     *weakTV   = tableView;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UITableViewCell *cell = weakCell;
                    UITableView     *tv   = weakTV;
                    // Guards stream-close : si l'un des deux objets est mort,
                    // ou si la cellule n'est plus dans la fenêtre (stream fermé),
                    // ou si la cellule a été sortie de la table (recyclage en cours)
                    // → on abandonne pour éviter EXC_BAD_ACCESS sur les ivars Swift.
                    if (!cell || !tv) return;
                    if (!cell.window || !tv.window) return;
                    if (cell.superview != tv) return;

                    CGFloat targetSize = (CGFloat)[[NSUserDefaults standardUserDefaults]
                        integerForKey:@"s7tv_emote_size"] ?: 30.0;

                    // ── Collecter les emote layers ───────────────────────────────────
                    // On repère les layers qui ont un sublayer "Animated" (= emote 7TV)
                    NSMutableArray<CALayer *> *emoteLayers = [NSMutableArray array];
                    NSMutableArray<CALayer *> *layerQueue = [NSMutableArray arrayWithArray:cell.layer.sublayers];
                    while (layerQueue.count > 0) {
                        CALayer *l = layerQueue[0];
                        [layerQueue removeObjectAtIndex:0];
                        for (CALayer *sub in l.sublayers) {
                            if ([NSStringFromClass(object_getClass(sub)) containsString:@"Animated"]) {
                                [emoteLayers addObject:l];
                                break;
                            }
                        }
                        if (l.sublayers) [layerQueue addObjectsFromArray:l.sublayers];
                    }

                    if (emoteLayers.count == 0) return;

                    // ── Ring buffer : récupérer les emotes ordonnées ─────────────────
                    // injectSevenTVEmotesIntoIRCMessage: stocke les emotes dans l'ordre
                    // du message IRC. On retrouve la séquence correspondant au nombre
                    // de layers détectés dans cette cellule.
                    SevenTVManager *animMgr = [SevenTVManager sharedManager];
                    NSArray<SevenTVEmote *> *emoteSequence =
                        [animMgr popEmoteSequenceForCount:emoteLayers.count];

                    // Construire orderedRatios depuis la séquence du ring buffer
                    NSMutableArray<NSNumber *> *orderedRatios = [NSMutableArray array];
                    if (emoteSequence) {
                        NSMutableDictionary *ratios = [animMgr emoteRatios];
                        for (SevenTVEmote *em in emoteSequence) {
                            if (em.width > 0 && em.height > 0) {
                                [orderedRatios addObject:@((CGFloat)em.width / (CGFloat)em.height)];
                            } else {
                                NSNumber *rn = ratios[em.emoteID];
                                [orderedRatios addObject:rn ?: @(1.0)];
                            }
                        }
                    }

                    // ── Dump MULTI-ÉCHANTILLONS désactivé (mission accomplie) ──────────
                    static NSInteger s_animSampleCount = 0;
                    static const NSInteger kS7TVAnimMaxSamples = 0; // 0 = désactivé
                    static BOOL s_displayLayerSwizzled = NO;
                    static NSMutableDictionary *s_displayCounts = nil;
                    static BOOL s_initFPSSwizzled = NO;
                    if (s_animSampleCount < kS7TVAnimMaxSamples && emoteLayers.count > 0) {
                        s_animSampleCount++;
                        NSInteger sampleIdx = s_animSampleCount;
                        SevenTVManager *mgr = [SevenTVManager sharedManager];
                        CALayer *sample = emoteLayers.firstObject;

                        // 1. Classe + frame du layer parent (ImageAttachmentLayer)
                        Class parentClass = object_getClass(sample);
                        [mgr log:@"🎞[%ld] parent: %@  frame=(%.1f,%.1f,%.1f,%.1f)",
                         (long)sampleIdx, NSStringFromClass(parentClass),
                         sample.frame.origin.x, sample.frame.origin.y,
                         sample.frame.size.width, sample.frame.size.height];

                        // 2. iVars du parent + encodages (pour repérer "content")
                        unsigned int pic = 0;
                        Ivar *piv = class_copyIvarList(parentClass, &pic);
                        for (unsigned int i = 0; i < pic; i++) {
                            const char *enc = ivar_getTypeEncoding(piv[i]);
                            [mgr log:@"🎞[%ld]   parent iVar: %s (%s)",
                             (long)sampleIdx, ivar_getName(piv[i]), enc ?: "?"];
                        }
                        free(piv);

                        // 3. Quelles méthodes le parent expose-t-il vraiment ? (sans rien lire)
                        s7tvLogResponds(sample, @[
                            @"content", @"setContent:",
                            @"currentDisplayMode", @"setCurrentDisplayMode:",
                            @"animatedImageLayer", @"setAnimatedImageLayer:",
                            @"staticImageLayer", @"setStaticImageLayer:",
                            @"currentImageLayer", @"setCurrentImageLayer:",
                            @"networkImageRequester", @"setNetworkImageRequester:"
                        ], sampleIdx, @"parent");

                        // 4. Sublayers (AnimatedImageAttachmentLayer) — via API publique
                        for (CALayer *sub in sample.sublayers) {
                            Class sc = object_getClass(sub);
                            [mgr log:@"🎞[%ld] sublayer: %@  bounds=(%.1fx%.1f)",
                             (long)sampleIdx, NSStringFromClass(sc),
                             sub.bounds.size.width, sub.bounds.size.height];

                            // iVars + encodages
                            unsigned int ic = 0;
                            Ivar *iv = class_copyIvarList(sc, &ic);
                            for (unsigned int i = 0; i < ic; i++) {
                                const char *enc = ivar_getTypeEncoding(iv[i]);
                                [mgr log:@"🎞[%ld]   iVar: %s (%s)",
                                 (long)sampleIdx, ivar_getName(iv[i]), enc ?: "?"];
                            }
                            free(iv);

                            // Méthodes + encodages (notamment initWithFPS: et displayLayer:)
                            unsigned int mc = 0;
                            Method *mv = class_copyMethodList(sc, &mc);
                            for (unsigned int i = 0; i < mc; i++) {
                                const char *enc = method_getTypeEncoding(mv[i]);
                                [mgr log:@"🎞[%ld]   method: %@ (%s)",
                                 (long)sampleIdx, NSStringFromSelector(method_getName(mv[i])), enc ?: "?"];
                            }

                            // 5. Swizzle displayLayer: (une seule fois, toutes instances confondues)
                            //    — uniquement si l'encodage correspond au pattern attendu
                            //    (void return, 1 argument objet), pour éviter tout mismatch d'ABI.
                            if (!s_displayLayerSwizzled) {
                                SEL displaySel = NSSelectorFromString(@"displayLayer:");
                                Method dm = class_getInstanceMethod(sc, displaySel);
                                if (dm) {
                                    const char *denc = method_getTypeEncoding(dm);
                                    if (denc && denc[0] == 'v' && strchr(denc, '@') != NULL) {
                                        s_displayLayerSwizzled = YES;
                                        s_displayCounts = [NSMutableDictionary dictionary];
                                        IMP origIMP = method_getImplementation(dm);
                                        IMP newIMP = imp_implementationWithBlock(^(id self_, id layerArg){
                                            @try {
                                                NSValue *key = [NSValue valueWithNonretainedObject:self_];
                                                @synchronized (s_displayCounts) {
                                                    NSNumber *c = s_displayCounts[key];
                                                    s_displayCounts[key] = @(c.integerValue + 1);
                                                }
                                            } @catch (__unused NSException *e) {}
                                            @try {
                                                ((void(*)(id,SEL,id))origIMP)(self_, displaySel, layerArg);
                                            } @catch (__unused NSException *e) {}
                                        });
                                        method_setImplementation(dm, newIMP);
                                        [mgr log:@"🎞 displayLayer: swizzlé pour comptage (encoding=%s)", denc];
                                    } else {
                                        [mgr log:@"🎞 displayLayer: encoding inattendu (%s), pas de swizzle", denc ?: "?"];
                                    }
                                }
                            }
                            free(mv);

                            // 5b. Swizzle initWithFPS: (encodage @24@0:8q16 = instancetype(int64_t))
                            //     — confirmé sur l'échantillon précédent, donc safe à hooker.
                            if (!s_initFPSSwizzled) {
                                SEL fpsSel = NSSelectorFromString(@"initWithFPS:");
                                Method fm = class_getInstanceMethod(sc, fpsSel);
                                if (fm) {
                                    const char *fenc = method_getTypeEncoding(fm);
                                    if (fenc && fenc[0] == '@' && strchr(fenc, 'q') != NULL) {
                                        s_initFPSSwizzled = YES;
                                        IMP origFPSIMP = method_getImplementation(fm);
                                        IMP newFPSIMP = imp_implementationWithBlock(^id(id self_, int64_t fps){
                                            [[SevenTVManager sharedManager] log:@"🎞 initWithFPS: fps=%lld classe=%@",
                                             (long long)fps, NSStringFromClass(object_getClass(self_))];
                                            @try {
                                                return ((id(*)(id,SEL,int64_t))origFPSIMP)(self_, fpsSel, fps);
                                            } @catch (__unused NSException *e) {
                                                return self_;
                                            }
                                        });
                                        method_setImplementation(fm, newFPSIMP);
                                        [mgr log:@"🎞 initWithFPS: swizzlé pour log (encoding=%s)", fenc];
                                    } else {
                                        [mgr log:@"🎞 initWithFPS: encoding inattendu (%s), pas de swizzle", fenc ?: "?"];
                                    }
                                }
                            }
                            // 5c. Quelles méthodes le sublayer animé expose-t-il vraiment ?
                            s7tvLogResponds(sub, @[
                                @"invalidationToken", @"setInvalidationToken:",
                                @"networkImageRequester", @"setNetworkImageRequester:",
                                @"startAnimating", @"stopAnimating", @"play", @"pause",
                                @"setFps:", @"fps", @"setPaused:", @"isPaused",
                                @"currentFrame", @"setCurrentFrame:"
                            ], sampleIdx, @"sublayer");

                            // 5d. Encodage ObjC de setCurrentFrame: et startAnimating
                            // → détermine le type exact de l'argument attendu
                            for (NSString *selName in @[@"setCurrentFrame:", @"startAnimating",
                                                        @"stopAnimating", @"currentFrame"]) {
                                Method m = class_getInstanceMethod(object_getClass(sub),
                                                                   NSSelectorFromString(selName));
                                if (m) {
                                    [mgr log:@"🔬[%ld] %@ → encoding=%s",
                                     (long)sampleIdx, selName, method_getTypeEncoding(m)];
                                }
                            }

                            // 6. Après 3s : compteur displayLayer:
                            __weak CALayer *weakSub = sub;
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                CALayer *strongSub = weakSub;
                                NSInteger count = 0;
                                if (strongSub && s_displayCounts) {
                                    NSValue *key = [NSValue valueWithNonretainedObject:strongSub];
                                    @synchronized (s_displayCounts) {
                                        count = [s_displayCounts[key] integerValue];
                                    }
                                }
                                [[SevenTVManager sharedManager] log:@"🎞[%ld] displayLayer: appelé %ld fois en 3s",
                                 (long)sampleIdx, (long)count];
                            });
                        }
                    }
                    // ─────────────────────────────────────────────────────────────

                    NSInteger emoteIndex = 0;
                    [CATransaction begin];
                    [CATransaction setDisableActions:YES];
                    for (CALayer *caLayer in emoteLayers) {
                        CGRect f = caLayer.frame;
                        if (f.size.width <= 0 || f.size.height <= 0) { emoteIndex++; continue; }
                        CGFloat ratio = (emoteIndex < (NSInteger)orderedRatios.count)
                            ? orderedRatios[emoteIndex].floatValue
                            : f.size.width / f.size.height;
                        emoteIndex++;
                        CGFloat newWidth = targetSize * ratio;
                        caLayer.bounds = CGRectMake(0, 0, newWidth, targetSize);
                        caLayer.frame  = CGRectMake(f.origin.x,
                                                    f.origin.y + (f.size.height - targetSize) / 2.0,
                                                    newWidth, targetSize);
                    }
                    [CATransaction commit];

                    // ── Animation WebP pour les emotes 7TV animées ──────────────────
                    // Pour chaque emote layer, on cherche son sublayer AnimatedImageAttachmentLayer,
                    // on récupère l'image WebP depuis NSURLCache, on décode les frames avec ImageIO,
                    // et on les cycle via setCurrentFrame: + CADisplayLink.
                    // Clé associated object pour stocker/stopper le CADisplayLink au recyclage.
                    static const char kS7TVDisplayLink = 0;

                    NSInteger animIdx = 0;
                    for (CALayer *emoteLayer in emoteLayers) {
                        // Trouver le sublayer AnimatedImageAttachmentLayer
                        CALayer *animSub = nil;
                        for (CALayer *sub in emoteLayer.sublayers) {
                            if ([NSStringFromClass(object_getClass(sub)) containsString:@"Animated"]) {
                                animSub = sub;
                                break;
                            }
                        }
                        if (!animSub) { animIdx++; continue; }

                        // Stopper le timer existant sur ce layer si recyclage
                        objc_setAssociatedObject(animSub, &kS7TVDisplayLink, nil,
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                        // Trouver l'emote 7TV animée correspondante à cet index
                        // via la séquence du ring buffer (ordre garanti)
                        NSString *emoteID = nil;
                        BOOL isAnimated = NO;
                        if (emoteSequence && animIdx < (NSInteger)emoteSequence.count) {
                            SevenTVEmote *em = emoteSequence[animIdx];
                            emoteID   = em.emoteID;
                            isAnimated = em.isAnimated;
                        }

                        animIdx++;
                        [animMgr log:@"🔎 animIdx=%ld emoteID=%@ isAnimated=%d seqCount=%ld",
                         (long)(animIdx-1), emoteID ?: @"(nil)", isAnimated,
                         (long)emoteSequence.count];
                        if (!emoteID) continue;

                        // Récupérer les données WebP depuis NSURLCache
                        NSString *cacheURLStr = [NSString stringWithFormat:
                            @"https://cdn.7tv.app/emote/%@/4x.webp", emoteID];
                        NSURL *cacheURL = [NSURL URLWithString:cacheURLStr];
                        NSURLRequest *cacheReq = [NSURLRequest requestWithURL:cacheURL];
                        NSCachedURLResponse *cached = [[SevenTVURLProtocol sharedEmoteCache]
                                                        cachedResponseForRequest:cacheReq];
                        if (!cached) {
                            cacheURLStr = [NSString stringWithFormat:
                                @"https://cdn.7tv.app/emote/%@/2x.webp", emoteID];
                            cacheURL = [NSURL URLWithString:cacheURLStr];
                            cacheReq = [NSURLRequest requestWithURL:cacheURL];
                            cached = [[SevenTVURLProtocol sharedEmoteCache]
                                       cachedResponseForRequest:cacheReq];
                        }
                        [animMgr log:@"🔎 cache=%@ url=%@", cached ? @"HIT" : @"MISS", cacheURLStr];
                        if (!cached) continue;

                        NSData *webpData = cached.data;
                        if (!webpData || webpData.length == 0) continue;

                        // Décoder les frames avec ImageIO
                        CGImageSourceRef src = CGImageSourceCreateWithData(
                            (__bridge CFDataRef)webpData, NULL);
                        if (!src) continue;

                        NSInteger frameCount = (NSInteger)CGImageSourceGetCount(src);
                        [animMgr log:@"🔎 frameCount=%ld isAnimated=%d", (long)frameCount, isAnimated];
                        if (frameCount <= 1) { CFRelease(src); continue; }

                        // Extraire les frames et les durées
                        NSMutableArray<UIImage *> *frames = [NSMutableArray array];
                        NSMutableArray<NSNumber *> *delays = [NSMutableArray array];
                        for (NSInteger fi = 0; fi < frameCount; fi++) {
                            CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, fi, NULL);
                            if (!cgImg) continue;
                            [frames addObject:[UIImage imageWithCGImage:cgImg]];
                            CGImageRelease(cgImg);

                            // Lire la durée de la frame depuis les métadonnées
                            NSDictionary *props = (__bridge_transfer NSDictionary *)
                                CGImageSourceCopyPropertiesAtIndex(src, fi, NULL);
                            NSDictionary *gifProps = props[@"{GIF}"];
                            NSDictionary *webpProps = props[@"{WebP}"];
                            NSNumber *delay = webpProps[@"DelayTime"]
                                           ?: gifProps[@"DelayTime"]
                                           ?: @(0.1);
                            CGFloat d = delay.floatValue < 0.011 ? 0.1 : delay.floatValue;
                            [delays addObject:@(d)];
                        }
                        CFRelease(src);

                        if (frames.count == 0) continue;

                        // Wrapper pour éviter de capturer animSub directement
                        __block NSInteger frameIdx = 0;
                        __block CFTimeInterval lastTime = 0;
                        __block CFTimeInterval accumulator = 0;
                        __weak CALayer *weakAnimSub = animSub;
                        NSArray<UIImage *> *framesCopy = [frames copy];
                        NSArray<NSNumber *> *delaysCopy = [delays copy];

                        // dispatch_source comme timer pour cycler les frames

                        CGFloat frameDuration = delaysCopy[0].floatValue;
                        dispatch_source_t timer = dispatch_source_create(
                            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
                        dispatch_source_set_timer(timer,
                            dispatch_time(DISPATCH_TIME_NOW, 0),
                            (uint64_t)(frameDuration * NSEC_PER_SEC),
                            (uint64_t)(0.005 * NSEC_PER_SEC));

                        dispatch_source_set_event_handler(timer, ^{
                            CALayer *sub = weakAnimSub;
                            if (!sub || !sub.superlayer || !sub.superlayer.superlayer) {
                                dispatch_source_cancel(timer);
                                return;
                            }
                            UIImage *frame = framesCopy[frameIdx % framesCopy.count];
                            @try {
                                SEL setCF = NSSelectorFromString(@"setCurrentFrame:");
                                void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))
                                    [sub methodForSelector:setCF];
                                if (fn) fn(sub, setCF, frame);
                            } @catch (__unused NSException *e) {}
                            frameIdx = (frameIdx + 1) % (NSInteger)framesCopy.count;
                            // Mettre à jour l'intervalle pour la prochaine frame
                            CGFloat nextDelay = delaysCopy[frameIdx % delaysCopy.count].floatValue;
                            dispatch_source_set_timer(timer,
                                dispatch_time(DISPATCH_TIME_NOW,
                                              (uint64_t)(nextDelay * NSEC_PER_SEC)),
                                (uint64_t)(nextDelay * NSEC_PER_SEC),
                                (uint64_t)(0.005 * NSEC_PER_SEC));
                        });

                        dispatch_resume(timer);

                        // Stocker le timer en associated object sur le sublayer
                        // pour l'invalider au recyclage (prochain passage dans willDisplayCell)
                        objc_setAssociatedObject(animSub, &kS7TVDisplayLink,
                            [[S7TVTimerWrapper alloc] initWithTimer:timer],
                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                        [animMgr log:@"🎬 Animation démarrée: emote=%@ frames=%ld",
                         emoteID, (long)framesCopy.count];
                    }
                    // ────────────────────────────────────────────────────────────────
                });
            });

            method_setImplementation(origMethod, newIMP);
            [[SevenTVManager sharedManager] log:@"✅ willDisplayCell hooké (avec délai 100ms)"];

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
