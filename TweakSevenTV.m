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
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVLogo.h"
#import "SevenTVSettingsController.h"
#import "SevenTVAdBlock.h"
static inline BOOL _s7tv_bool(NSString *k) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:k];
}
#define S7TVBool(k) _s7tv_bool(k)

// Forward declarations
static NSString *s7tv_sanitizeM3U8(NSString *playlist, BOOL *didBypass);
static void s7tv_detect_ad_in_playlist(NSString *playlist);

#import <Network/Network.h>
#import <AVFoundation/AVFoundation.h>



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
// MARK: - Hijack du bouton Bits → bouton 7TV
// ────────────────────────────────────────────────────────────

@interface UIView (S7TVChatInputHook)
- (void)s7tv_didMoveToWindow;
@end

@implementation UIView (S7TVChatInputHook)

- (void)s7tv_didMoveToWindow {
    [self s7tv_didMoveToWindow]; // appel original

    NSString *selfClass = NSStringFromClass([self class]);

    // ── Force _areEmoteAnimationsEnabled via offset mémoire direct ──────────
    if ([selfClass isEqualToString:@"Twitch.ChatTranscriptView"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            Class cls = NSClassFromString(@"Twitch.ChatTranscriptView");
            Ivar ivar = class_getInstanceVariable(cls, "_areEmoteAnimationsEnabled");
            if (!ivar) {
                [[SevenTVManager sharedManager] log:@"❌ iVar _areEmoteAnimationsEnabled introuvable"];
                return;
            }
            ptrdiff_t offset = ivar_getOffset(ivar);
            // Lire la valeur actuelle (BOOL = 1 byte)
            BOOL *ptr = (BOOL *)((uint8_t *)(__bridge void *)self + offset);
            BOOL before = *ptr;
            // Forcer à YES
            *ptr = YES;
            BOOL after = *ptr;
            [[SevenTVManager sharedManager] log:@"🎬 _areEmoteAnimationsEnabled: %d → %d (offset=%td)",
             before, after, offset];
        });
    }

    // ── Hijack du bouton Bits → bouton 7TV ───────────────────────────────────
    if (![selfClass isEqualToString:@"Twitch.ChatInputView"]) return;
    UIView *chatInputView = self;

    if (objc_getAssociatedObject(chatInputView, &kS7TVTextFieldTagged)) return;
    objc_setAssociatedObject(chatInputView, &kS7TVTextFieldTagged, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{

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

            objc_setAssociatedObject(bitsBtn, &kS7TVTextFieldTagged, chatInputView,
                                     OBJC_ASSOCIATION_ASSIGN);

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

            objc_setAssociatedObject(btn, &kS7TVTextFieldTagged, chatInputView,
                                     OBJC_ASSOCIATION_ASSIGN);
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
    UIView *chatInputView = objc_getAssociatedObject(sender, &kS7TVTextFieldTagged);
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
                        if (pl) s7tv_detect_ad_in_playlist(pl);
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

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [mgr log:@"  🔍 SCAN CHAT @ (%.0f,%.0f) ──────────────", pt.x, pt.y];
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:self];
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
// MARK: - Point d'entrée __attribute__((constructor))
// ────────────────────────────────────────────────────────────



// ────────────────────────────────────────────────────────────
// MARK: - Blocked URLs + HLS Sanitizer hook
// ────────────────────────────────────────────────────────────

// Vérifie si une URL doit être bloquée
static BOOL s7tv_shouldBlockURL(NSURL *url) {
    if (!url) return NO;
    if (!S7TVBool(kTCAdsDisabled)) return NO;
    NSArray<NSString *> *blocked = [[NSUserDefaults standardUserDefaults] arrayForKey:kTCBlockedURLList] ?: @[];
    NSString *absolute = url.absoluteString.lowercaseString;
    NSString *host = url.host.lowercaseString ?: @"";
    for (NSString *rule in blocked) {
        NSString *r = rule.lowercaseString;
        if ([r hasPrefix:@"re:"]) {
            NSString *pattern = [r substringFromIndex:3];
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                options:NSRegularExpressionCaseInsensitive error:nil];
            if ([regex numberOfMatchesInString:absolute options:0
                    range:NSMakeRange(0, absolute.length)] > 0) return YES;
        } else {
            if ([host containsString:r] || [absolute containsString:r]) return YES;
        }
    }
    return NO;
}

// Sanitize une playlist HLS — supprime les segments pub
static NSString *s7tv_sanitizeM3U8(NSString *playlist, BOOL *didBypass) {
    if (didBypass) *didBypass = NO;
    if (!S7TVBool(kTCStreamProxySanitizeM3U8)) return playlist;
    NSArray<NSString *> *lines = [playlist componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:lines.count];
    BOOL skipNext = NO;
    NSString *adType = nil;
    for (NSString *line in lines) {
        NSString *t = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        BOOL isAdMarker = NO;
        if ([t containsString:@"#EXT-X-SCTE35"] ||
            [t containsString:@"#EXT-X-DATERANGE"]) {
            isAdMarker = YES;
            if (!adType) adType = @"Commercial";
        }
        if ([t containsString:@"stitched-ad"] ||
            [t containsString:@"X-TV-TWITCH-AD"]) {
            isAdMarker = YES;
            if (!adType) adType = @"Stitched";
        }
        if ([t containsString:@"ad_tag"] ||
            [t containsString:@"twitchsvc.net/ad"]) {
            isAdMarker = YES;
            if (!adType) adType = @"Commercial";
        }
        if ([t hasPrefix:@"#EXT-X-DISCONTINUITY"] && skipNext) {
            isAdMarker = YES;
        }
        if (isAdMarker) { skipNext = YES; continue; }
        if (skipNext && t.length > 0 && ![t hasPrefix:@"#"]) {
            skipNext = NO; continue; // skip segment URI pub
        }
        skipNext = NO;
        [out addObject:line];
    }
    if (adType) {
        if (didBypass) *didBypass = YES;
        // Stocker adType pour l'indicator
        [[NSUserDefaults standardUserDefaults]
            setObject:adType forKey:@"s7tv_last_ad_type"];
    }
    return [out componentsJoinedByString:@"\n"];
}

// Hook NSURLSession — blocage URLs + sanitize HLS
@interface NSURLSession (S7TVAdBlock)
- (NSURLSessionDataTask *)s7tv_adblock_dataTaskWithRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler;
@end

@implementation NSURLSession (S7TVAdBlock)

- (NSURLSessionDataTask *)s7tv_adblock_dataTaskWithRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {

    // Bloquer les URLs de pub
    if (s7tv_shouldBlockURL(request.URL)) {
        if (completionHandler) {
            NSError *blocked = [NSError errorWithDomain:NSURLErrorDomain
                code:NSURLErrorCancelled userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(nil, nil, blocked); });
        }
        return [self s7tv_adblock_dataTaskWithRequest:request completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){}];
    }

    // Sanitize HLS .m3u8
    NSString *path = request.URL.path.lowercaseString;
    BOOL isM3U8 = [path hasSuffix:@".m3u8"] || [path containsString:@"m3u8"];
    if (isM3U8 && S7TVBool(kTCStreamProxySanitizeM3U8) && completionHandler) {
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *resp, NSError *err) {
                if (data && !err) {
                    NSString *playlist = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if (playlist) {
                        BOOL didBypass1 = NO;
                        NSString *sanitized = s7tv_sanitizeM3U8(playlist, &didBypass1);
                        data = [sanitized dataUsingEncoding:NSUTF8StringEncoding];
                        if (didBypass1) s7tv_show_ad_indicator([[NSUserDefaults standardUserDefaults] stringForKey:@"s7tv_last_ad_type"]);
                    }
                }
                completionHandler(data, resp, err);
            };
        return [self s7tv_adblock_dataTaskWithRequest:request completionHandler:wrapped];
    }

    return [self s7tv_adblock_dataTaskWithRequest:request completionHandler:completionHandler];
}

@end

static void s7tv_swizzle_adblock(void) {
    NSURLSession *probe = [NSURLSession sessionWithConfiguration:
        [NSURLSessionConfiguration defaultSessionConfiguration]];
    Class cls = object_getClass(probe);
    s7tv_swizzle(cls, [NSURLSession class],
        @selector(dataTaskWithRequest:completionHandler:),
        @selector(s7tv_adblock_dataTaskWithRequest:completionHandler:));
}


// ────────────────────────────────────────────────────────────
// MARK: - Local Proxy TCP (nw_listener sur 127.0.0.1:9595)
// ────────────────────────────────────────────────────────────

static nw_listener_t s7tv_local_proxy_listener = nil;
static dispatch_queue_t s7tv_proxy_queue = nil;

// Forward d'une connexion cliente vers le vrai serveur
static void s7tv_forward_connection(nw_connection_t client_conn) {
    nw_connection_start(client_conn);
    nw_connection_receive(client_conn, 1, (uint32_t)65536,
        ^(dispatch_data_t content, nw_content_context_t ctx,
          bool is_complete, nw_error_t rx_err) {
            if (!content || rx_err) { nw_connection_cancel(client_conn); return; }

            NSData *reqData = (NSData *)content;
            NSString *reqStr = [[NSString alloc] initWithData:reqData
                encoding:NSUTF8StringEncoding];
            if (!reqStr) { nw_connection_cancel(client_conn); return; }

            // Extraire url= du query string
            NSString *targetURLStr = nil;
            NSRange urlRange = [reqStr rangeOfString:@"url="];
            if (urlRange.location != NSNotFound) {
                NSString *after = [reqStr substringFromIndex:
                    urlRange.location + 4];
                NSUInteger endPos = after.length;
                for (NSUInteger i = 0; i < after.length; i++) {
                    unichar c = [after characterAtIndex:i];
                    if (c == 32 || c == 13 || c == 10 || c == 38) {
                        endPos = i; break;
                    }
                }
                targetURLStr = [[after substringToIndex:endPos]
                    stringByRemovingPercentEncoding];
            }

            if (!targetURLStr.length) {
                const char *r400 = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
                NSData *d400 = [NSData dataWithBytes:r400 length:strlen(r400)];
                nw_connection_send(client_conn, (dispatch_data_t)d400,
                    NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                    ^(nw_error_t e){ nw_connection_cancel(client_conn); });
                return;
            }

            NSURL *targetURL = [NSURL URLWithString:targetURLStr];
            if (!targetURL) { nw_connection_cancel(client_conn); return; }

            // Copier headers HTTP
            NSMutableURLRequest *proxyReq = [NSMutableURLRequest
                requestWithURL:targetURL];
            proxyReq.timeoutInterval = 10.0;
            static const char *crlfcrlf = "\r\n\r\n";
            NSData *sep = [NSData dataWithBytes:crlfcrlf length:4];
            NSRange sepRange = [reqData rangeOfData:sep options:0
                range:NSMakeRange(0, reqData.length)];
            if (sepRange.location != NSNotFound) {
                NSData *hdrData = [reqData subdataWithRange:
                    NSMakeRange(0, sepRange.location)];
                NSString *hdrStr = [[NSString alloc] initWithData:hdrData
                    encoding:NSUTF8StringEncoding];
                static const char *crlf = "\r\n";
                NSData *crlfData = [NSData dataWithBytes:crlf length:2];
                NSMutableArray *hdrLines = [NSMutableArray array];
                NSUInteger pos = 0;
                while (pos < hdrData.length) {
                    NSRange r = [hdrData rangeOfData:crlfData options:0
                        range:NSMakeRange(pos, hdrData.length - pos)];
                    NSUInteger lineEnd = (r.location != NSNotFound)
                        ? r.location : hdrData.length;
                    NSData *lineData = [hdrData subdataWithRange:
                        NSMakeRange(pos, lineEnd - pos)];
                    NSString *lineStr = [[NSString alloc] initWithData:lineData
                        encoding:NSUTF8StringEncoding];
                    if (lineStr) [hdrLines addObject:lineStr];
                    pos = (r.location != NSNotFound)
                        ? r.location + 2 : hdrData.length;
                }
                for (NSUInteger i = 1; i < hdrLines.count; i++) {
                    NSString *hl = hdrLines[i];
                    NSRange colon = [hl rangeOfString:@": "];
                    if (colon.location == NSNotFound) continue;
                    NSString *key = [hl substringToIndex:colon.location];
                    NSString *val = [hl substringFromIndex:colon.location + 2];
                    if ([key.lowercaseString isEqualToString:@"host"]) continue;
                    [proxyReq setValue:val forHTTPHeaderField:key];
                }
            }

            NSURLSessionConfiguration *proxyCfg =
                [NSURLSessionConfiguration ephemeralSessionConfiguration];
            proxyCfg.timeoutIntervalForRequest = 10.0;
            NSURLSession *proxySession =
                [NSURLSession sessionWithConfiguration:proxyCfg];

            [[proxySession dataTaskWithRequest:proxyReq
                completionHandler:^(NSData *data, NSURLResponse *resp,
                                    NSError *error) {
                if (error || !data) {
                    const char *r502 =
                        "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n";
                    NSData *d502 = [NSData dataWithBytes:r502 length:strlen(r502)];
                    nw_connection_send(client_conn, (dispatch_data_t)d502,
                        NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                        ^(nw_error_t e){ nw_connection_cancel(client_conn); });
                    return;
                }
                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
                NSString *ct = httpResp.allHeaderFields[@"Content-Type"]
                    ?: @"application/octet-stream";
                NSData *body = data;
                if ([ct containsString:@"mpegurl"] ||
                    [targetURLStr containsString:@"m3u8"]) {
                    NSString *pl = [[NSString alloc] initWithData:data
                        encoding:NSUTF8StringEncoding];
                    if (pl) {
                        s7tv_detect_ad_in_playlist(pl);
                        BOOL didBypass2 = NO;
                        NSString *san = s7tv_sanitizeM3U8(pl, &didBypass2);
                        body = [san dataUsingEncoding:NSUTF8StringEncoding] ?: data;
                        if (didBypass2) s7tv_show_ad_indicator([[NSUserDefaults standardUserDefaults] stringForKey:@"s7tv_last_ad_type"]);
                    }
                }
                // Construire reponse HTTP
                NSMutableData *fullResp = [NSMutableData data];
                void (^appendStr)(NSString *) = ^(NSString *s) {
                    [fullResp appendData:[s dataUsingEncoding:NSUTF8StringEncoding]];
                };
                appendStr([NSString stringWithFormat:
                    @"HTTP/1.1 %ld OK\r\n", (long)httpResp.statusCode]);
                appendStr([NSString stringWithFormat:
                    @"Content-Type: %@\r\n", ct]);
                appendStr([NSString stringWithFormat:
                    @"Content-Length: %lu\r\n", (unsigned long)body.length]);
                appendStr(@"Access-Control-Allow-Origin: *\r\n");
                appendStr(@"\r\n");
                [fullResp appendData:body];
                nw_connection_send(client_conn,
                    (dispatch_data_t)(NSData *)fullResp,
                    NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true,
                    ^(nw_error_t e){ nw_connection_cancel(client_conn); });
            }] resume];
        }
    );
}

static void s7tv_start_local_proxy(void) {
    if (!S7TVBool(kTCStreamProxyLocalEnabled)) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSInteger port = [ud integerForKey:kTCStreamProxyLocalPort];
    if (port <= 0) port = 9595;
    if (s7tv_local_proxy_listener) {
        nw_listener_cancel(s7tv_local_proxy_listener);
        s7tv_local_proxy_listener = nil;
    }
    if (!s7tv_proxy_queue)
        s7tv_proxy_queue = dispatch_queue_create(
            "app.7tv.localproxy", DISPATCH_QUEUE_SERIAL);
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,
        NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1",
        [[NSString stringWithFormat:@"%ld", (long)port] UTF8String]);
    nw_parameters_set_local_endpoint(params, endpoint);
    s7tv_local_proxy_listener = nw_listener_create(params);
    nw_listener_set_queue(s7tv_local_proxy_listener, s7tv_proxy_queue);
    nw_listener_set_new_connection_handler(s7tv_local_proxy_listener,
        ^(nw_connection_t conn) { s7tv_forward_connection(conn); });
    nw_listener_set_state_changed_handler(s7tv_local_proxy_listener,
        ^(nw_listener_state_t state, nw_error_t err) {
            if (state == nw_listener_state_ready)
                [[SevenTVManager sharedManager]
                    log:@"Local proxy OK port %ld", (long)port];
            else if (state == nw_listener_state_failed)
                [[SevenTVManager sharedManager]
                    log:@"Local proxy FAIL port %ld", (long)port];
        });
    nw_listener_start(s7tv_local_proxy_listener);
}

static void s7tv_stop_local_proxy(void) {
    if (s7tv_local_proxy_listener) {
        nw_listener_cancel(s7tv_local_proxy_listener);
        s7tv_local_proxy_listener = nil;
    }
}

static void s7tv_observe_proxy_prefs(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSUserDefaultsDidChangeNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        static BOOL lastState = NO;
        BOOL current = S7TVBool(kTCStreamProxyLocalEnabled);
        if (current != lastState) {
            lastState = current;
            if (current) s7tv_start_local_proxy();
            else s7tv_stop_local_proxy();
        }
    }];
}


// ────────────────────────────────────────────────────────────
// MARK: - Ad Bypassed Indicator (overlay sur le player)
// ────────────────────────────────────────────────────────────

static UILabel *s7tv_indicator_label = nil;
static NSTimer *s7tv_indicator_timer = nil;

static void s7tv_show_ad_indicator(NSString *adType) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!S7TVBool(kTCAdsBypassIndicatorEnabled)) return;

        // Trouver la key window
        UIWindow *keyWin = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
            if ([sc isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)sc).windows)
                    if (w.isKeyWindow) { keyWin = w; break; }
        if (!keyWin) return;

        if (!s7tv_indicator_label) {
            s7tv_indicator_label = [[UILabel alloc] init];
            s7tv_indicator_label.backgroundColor =
                [UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:0.88];
            s7tv_indicator_label.textColor =
                [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
            s7tv_indicator_label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
            s7tv_indicator_label.layer.cornerRadius = 8;
            s7tv_indicator_label.clipsToBounds = YES;
            s7tv_indicator_label.textAlignment = NSTextAlignmentCenter;
            s7tv_indicator_label.translatesAutoresizingMaskIntoConstraints = NO;
        }

        // Texte
        BOOL showTag = S7TVBool(kTCAdsBypassIndicatorTagEnabled);
        NSString *text = showTag && adType.length
            ? [NSString stringWithFormat:@"  ✓ Ad Bypassed · %@  ", adType]
            : @"  ✓ Ad Bypassed  ";
        s7tv_indicator_label.text = text;
        s7tv_indicator_label.alpha = 1.0;

        if (!s7tv_indicator_label.superview) {
            [keyWin addSubview:s7tv_indicator_label];
            [NSLayoutConstraint activateConstraints:@[
                [s7tv_indicator_label.topAnchor
                    constraintEqualToAnchor:keyWin.safeAreaLayoutGuide.topAnchor constant:12],
                [s7tv_indicator_label.centerXAnchor
                    constraintEqualToAnchor:keyWin.centerXAnchor],
                [s7tv_indicator_label.heightAnchor constraintEqualToConstant:28],
            ]];
        }
        [keyWin bringSubviewToFront:s7tv_indicator_label];

        // Auto-hide après 4s
        [s7tv_indicator_timer invalidate];
        s7tv_indicator_timer = [NSTimer scheduledTimerWithTimeInterval:4.0
            target:[NSBlockOperation blockOperationWithBlock:^{
                [UIView animateWithDuration:0.4 animations:^{
                    s7tv_indicator_label.alpha = 0.0;
                }];
            }]
            selector:@selector(main) userInfo:nil repeats:NO];
    });
}

// Détecter les segments pub dans les réponses HLS et déclencher l'indicator
static void s7tv_detect_ad_in_playlist(NSString *playlist) {
    if (!playlist.length) return;
    // Indicator declenche par sanitize - ici juste log
    if ([playlist containsString:@"stitched-ad"] ||
        [playlist containsString:@"X-TV-TWITCH-AD"] ||
        [playlist containsString:@"#EXT-X-SCTE35"] ||
        [playlist containsString:@"ad_tag"]) {
        [[SevenTVManager sharedManager] log:@"Ad detected in playlist"];
    }
}

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

    // Section 7TV dans les paramètres Twitch
    s7tv_swizzle_account_menu();

    // Blocked URLs + HLS Sanitizer
    s7tv_swizzle_adblock();

    // Observer les changements Local Proxy
    s7tv_observe_proxy_prefs();

    // Setup sur le main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SevenTVManager sharedManager] setup];
        [NSURLProtocol registerClass:[SevenTVURLProtocol class]];
        [[SevenTVManager sharedManager] log:@"✅ SevenTVManager prêt, URLProtocol enregistré"];

        // Démarrer le local proxy si activé
        s7tv_start_local_proxy();

        // ── Dump multi-classes chat ───────────────────────────────────────
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            SevenTVManager *mgr = [SevenTVManager sharedManager];

            // Liste des classes à inspecter
            NSArray *classNames = @[
                @"Twitch.MessageStringView",
                @"Twitch.ChatMessageTableViewCell",
                @"Twitch.ChatTranscriptView",
            ];

            void (^dumpClass)(NSString *) = ^(NSString *className) {
                Class cls = NSClassFromString(className);
                if (!cls) {
                    [mgr log:@"❌ Classe introuvable: %@", className];
                    return;
                }
                [mgr log:@"════ DUMP: %@ ════", className];
                [mgr log:@"🔗 Superclasse: %@", NSStringFromClass(class_getSuperclass(cls))];

                // iVars
                unsigned int ivarCount = 0;
                Ivar *ivars = class_copyIvarList(cls, &ivarCount);
                [mgr log:@"📦 %u iVars:", ivarCount];
                for (unsigned int i = 0; i < ivarCount; i++) {
                    const char *name = ivar_getName(ivars[i]);
                    const char *type = ivar_getTypeEncoding(ivars[i]);
                    [mgr log:@"📦   %s :: %s", name, type ? type : "?"];
                }
                free(ivars);

                // Propriétés
                unsigned int propCount = 0;
                objc_property_t *props = class_copyPropertyList(cls, &propCount);
                [mgr log:@"🔑 %u propriétés:", propCount];
                for (unsigned int i = 0; i < propCount; i++) {
                    const char *name = property_getName(props[i]);
                    const char *attr = property_getAttributes(props[i]);
                    [mgr log:@"🔑   %s :: %s", name, attr ? attr : "?"];
                }
                free(props);

                // Méthodes
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(cls, &methodCount);
                [mgr log:@"📋 %u méthodes:", methodCount];
                for (unsigned int i = 0; i < methodCount; i++) {
                    const char *types = method_getTypeEncoding(methods[i]);
                    [mgr log:@"📋   %@ :: %s",
                     NSStringFromSelector(method_getName(methods[i])),
                     types ? types : "?"];
                }
                free(methods);

                [mgr log:@"════ FIN: %@ ════", className];
            };

            for (NSString *cn in classNames) {
                dumpClass(cn);
            }

            // Dump runtime d'une instance de MessageStringView si disponible
            [mgr log:@"🔎 Recherche instance MessageStringView en live..."];
            UIWindow *keyWin = nil;
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes)
                if ([sc isKindOfClass:[UIWindowScene class]])
                    for (UIWindow *w in ((UIWindowScene *)sc).windows)
                        if (w.isKeyWindow) { keyWin = w; break; }

            if (keyWin) {
                NSMutableArray *queue = [NSMutableArray arrayWithObject:keyWin];
                while (queue.count > 0) {
                    UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
                    [queue addObjectsFromArray:v.subviews];
                    if ([NSStringFromClass([v class]) isEqualToString:@"Twitch.MessageStringView"]) {
                        [mgr log:@"🔎 Instance trouvée! Dump KVC:"];
                        // Dump messageStringLayer
                        @try {
                            id layer = [v valueForKey:@"messageStringLayer"];
                            [mgr log:@"🔎   messageStringLayer: %@", NSStringFromClass([layer class])];
                            if (layer) {
                                // Dump sous-layers
                                NSArray *sublayers = [layer valueForKey:@"sublayers"];
                                [mgr log:@"🔎   sublayers count: %lu", (unsigned long)sublayers.count];
                                for (id sub in sublayers) {
                                    [mgr log:@"🔎     sublayer: %@", NSStringFromClass([sub class])];
                                }
                            }
                        } @catch (NSException *e) {
                            [mgr log:@"🔎   messageStringLayer KVC erreur: %@", e.reason];
                        }
                        // Dump networkImageRequester
                        @try {
                            id requester = [v valueForKey:@"networkImageRequester"];
                            [mgr log:@"🔎   networkImageRequester: %@", NSStringFromClass([requester class])];
                        } @catch (NSException *e) {
                            [mgr log:@"🔎   networkImageRequester KVC erreur: %@", e.reason];
                        }
                        // Dump delegate
                        @try {
                            id delegate = [v valueForKey:@"delegate"];
                            [mgr log:@"🔎   delegate: %@", NSStringFromClass([delegate class])];
                        } @catch (NSException *e) {
                            [mgr log:@"🔎   delegate KVC erreur: %@", e.reason];
                        }
                        break;
                    }
                }
            }
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
