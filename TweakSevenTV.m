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


    // Setup sur le main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SevenTVManager sharedManager] setup];
        [NSURLProtocol registerClass:[SevenTVURLProtocol class]];
        [[SevenTVManager sharedManager] log:@"✅ SevenTVManager prêt, URLProtocol enregistré"];

        // Démarrer le local proxy si activé

        // ── Hook willDisplayCell sur ChatTranscriptView ──────────────────
        // On swizzle tableView:willDisplayCell:forRowAtIndexPath: pour lire
        // messageStringLayer et networkImageRequester en live sur chaque cellule.
        // But : comprendre comment la taille des emotes est stockée.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            Class transcriptClass = NSClassFromString(@"Twitch.ChatTranscriptView");
            if (!transcriptClass) {
                [[SevenTVManager sharedManager] log:@"❌ ChatTranscriptView introuvable"];
                return;
            }

            SEL origSel = @selector(tableView:willDisplayCell:forRowAtIndexPath:);
            Method origMethod = class_getInstanceMethod(transcriptClass, origSel);
            if (!origMethod) {
                [[SevenTVManager sharedManager] log:@"❌ willDisplayCell introuvable"];
                return;
            }

            // iVar offset pour récupérer la MessageStringView depuis la cellule
            Class cellClass = NSClassFromString(@"Twitch.ChatMessageTableViewCell");
            Ivar msgViewIvar = class_getInstanceVariable(cellClass, "$__lazy_storage_$__messageStringView");
            ptrdiff_t msgViewOffset = msgViewIvar ? ivar_getOffset(msgViewIvar) : -1;

            // iVar offset pour messageStringLayer depuis MessageStringView
            Class msgStringViewClass = NSClassFromString(@"Twitch.MessageStringView");
            Ivar layerIvar = class_getInstanceVariable(msgStringViewClass, "messageStringLayer");
            ptrdiff_t layerOffset = layerIvar ? ivar_getOffset(layerIvar) : -1;

            // iVar offset pour networkImageRequester
            Ivar requesterIvar = class_getInstanceVariable(msgStringViewClass, "networkImageRequester");
            ptrdiff_t requesterOffset = requesterIvar ? ivar_getOffset(requesterIvar) : -1;

            [[SevenTVManager sharedManager] log:@"📐 Offsets — msgView:%td layer:%td requester:%td",
             msgViewOffset, layerOffset, requesterOffset];

            // Remplacer willDisplayCell par notre version
            static BOOL s_willDisplayCellHooked = NO;
            if (s_willDisplayCellHooked) return;
            s_willDisplayCellHooked = YES;

            IMP origIMP = method_getImplementation(origMethod);

            // Block qui sera appelé à chaque affichage de cellule
            IMP newIMP = imp_implementationWithBlock(^(id self_tv,
                                                       UITableView *tableView,
                                                       UITableViewCell *cell,
                                                       NSIndexPath *indexPath) {
                // Appel original
                ((void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))origIMP)
                    (self_tv, origSel, tableView, cell, indexPath);

                // On ne dumpe qu'une seule fois pour pas spammer les logs
                static BOOL s_dumped = NO;
                if (s_dumped) return;

                // Vérifier que c'est bien une ChatMessageTableViewCell
                if (![NSStringFromClass([cell class]) isEqualToString:@"Twitch.ChatMessageTableViewCell"]) return;

                s_dumped = YES;
                SevenTVManager *mgr = [SevenTVManager sharedManager];
                [mgr log:@"📐 ═══ DUMP willDisplayCell ═══"];

                // Récupérer MessageStringView via offset
                id msgStringView = nil;
                if (msgViewOffset >= 0) {
                    void **ptr = (void **)((uint8_t *)(__bridge void *)cell + msgViewOffset);
                    msgStringView = (__bridge id)*ptr;
                    [mgr log:@"📐 MessageStringView: %@", NSStringFromClass([msgStringView class])];
                }

                // Récupérer messageStringLayer via offset
                if (msgStringView && layerOffset >= 0) {
                    void **ptr = (void **)((uint8_t *)(__bridge void *)msgStringView + layerOffset);
                    id layer = (__bridge id)*ptr;
                    [mgr log:@"📐 messageStringLayer classe: %@", NSStringFromClass([layer class])];

                    if (layer) {
                        // Dump des sublayers
                        NSArray *sublayers = ((CALayer *)layer).sublayers;
                        [mgr log:@"📐 sublayers count: %lu", (unsigned long)sublayers.count];
                        for (CALayer *sub in sublayers) {
                            [mgr log:@"📐   sublayer: %@ bounds=(%.0fx%.0f) frame=(%.0f,%.0f,%.0f,%.0f)",
                             NSStringFromClass([sub class]),
                             sub.bounds.size.width, sub.bounds.size.height,
                             sub.frame.origin.x, sub.frame.origin.y,
                             sub.frame.size.width, sub.frame.size.height];

                            // Dump des sous-sous-layers
                            for (CALayer *sub2 in sub.sublayers) {
                                [mgr log:@"📐     sub-sublayer: %@ bounds=(%.0fx%.0f)",
                                 NSStringFromClass([sub2 class]),
                                 sub2.bounds.size.width, sub2.bounds.size.height];
                            }

                            // Dump iVars du sublayer
                            unsigned int ivarCount = 0;
                            Ivar *ivars = class_copyIvarList([sub class], &ivarCount);
                            if (ivarCount > 0 && ivarCount < 30) {
                                [mgr log:@"📐     iVars du sublayer:"];
                                for (unsigned int i = 0; i < ivarCount; i++) {
                                    [mgr log:@"📐       %s", ivar_getName(ivars[i])];
                                }
                            }
                            free(ivars);
                        }

                        // Dump iVars du layer principal
                        unsigned int ivarCount = 0;
                        Ivar *ivars = class_copyIvarList([layer class], &ivarCount);
                        [mgr log:@"📐 messageStringLayer iVars (%u):", ivarCount];
                        for (unsigned int i = 0; i < ivarCount; i++) {
                            [mgr log:@"📐   %s", ivar_getName(ivars[i])];
                        }
                        free(ivars);

                        // Méthodes du layer
                        unsigned int methodCount = 0;
                        Method *methods = class_copyMethodList([layer class], &methodCount);
                        [mgr log:@"📐 messageStringLayer méthodes (%u):", methodCount];
                        for (unsigned int i = 0; i < methodCount; i++) {
                            [mgr log:@"📐   %@", NSStringFromSelector(method_getName(methods[i]))];
                        }
                        free(methods);
                    }
                }

                // Récupérer networkImageRequester via offset
                if (msgStringView && requesterOffset >= 0) {
                    void **ptr = (void **)((uint8_t *)(__bridge void *)msgStringView + requesterOffset);
                    id requester = (__bridge id)*ptr;
                    [mgr log:@"📐 networkImageRequester classe: %@", NSStringFromClass([requester class])];

                    if (requester) {
                        // Dump iVars du requester
                        unsigned int ivarCount = 0;
                        Ivar *ivars = class_copyIvarList([requester class], &ivarCount);
                        [mgr log:@"📐 requester iVars (%u):", ivarCount];
                        for (unsigned int i = 0; i < ivarCount; i++) {
                            [mgr log:@"📐   %s", ivar_getName(ivars[i])];
                        }
                        free(ivars);

                        // Méthodes du requester
                        unsigned int methodCount = 0;
                        Method *methods = class_copyMethodList([requester class], &methodCount);
                        [mgr log:@"📐 requester méthodes (%u):", methodCount];
                        for (unsigned int i = 0; i < methodCount; i++) {
                            [mgr log:@"📐   %@", NSStringFromSelector(method_getName(methods[i]))];
                        }
                        free(methods);
                    }
                }

                // Dump orderedImageLayers en live
                if (msgStringView && layerOffset >= 0) {
                    void **ptr = (void **)((uint8_t *)(__bridge void *)msgStringView + layerOffset);
                    id layer = (__bridge id)*ptr;
                    if (layer) {
                        // Récupérer orderedImageLayers via iVar offset
                        Class msgLayerClass = [layer class];
                        Ivar imgLayersIvar = class_getInstanceVariable(msgLayerClass, "orderedImageLayers");
                        Ivar imgContentsIvar = class_getInstanceVariable(msgLayerClass, "orderedImageLayerContents");
                        Ivar msgStringIvar = class_getInstanceVariable(msgLayerClass, "messageString");

                        if (imgLayersIvar) {
                            ptrdiff_t imgLayersOffset = ivar_getOffset(imgLayersIvar);
                            void **imgLayersPtr = (void **)((uint8_t *)(__bridge void *)layer + imgLayersOffset);
                            id imgLayers = (__bridge id)*imgLayersPtr;
                            [mgr log:@"📐 orderedImageLayers type: %@", NSStringFromClass([imgLayers class])];
                            if ([imgLayers isKindOfClass:[NSArray class]]) {
                                NSArray *arr = (NSArray *)imgLayers;
                                [mgr log:@"📐 orderedImageLayers count: %lu", (unsigned long)arr.count];
                                for (id imgLayer in arr) {
                                    [mgr log:@"📐   imageLayer: %@ bounds=(%.1fx%.1f) frame=(%.1f,%.1f,%.1f,%.1f)",
                                     NSStringFromClass([imgLayer class]),
                                     ((CALayer *)imgLayer).bounds.size.width,
                                     ((CALayer *)imgLayer).bounds.size.height,
                                     ((CALayer *)imgLayer).frame.origin.x,
                                     ((CALayer *)imgLayer).frame.origin.y,
                                     ((CALayer *)imgLayer).frame.size.width,
                                     ((CALayer *)imgLayer).frame.size.height];
                                    // Dump iVars de chaque imageLayer
                                    unsigned int ic = 0;
                                    Ivar *iv = class_copyIvarList([imgLayer class], &ic);
                                    for (unsigned int i = 0; i < ic; i++) {
                                        [mgr log:@"📐     iVar: %s", ivar_getName(iv[i])];
                                    }
                                    free(iv);
                                }
                            }
                        }

                        if (msgStringIvar) {
                            ptrdiff_t msgStrOffset = ivar_getOffset(msgStringIvar);
                            void **msgStrPtr = (void **)((uint8_t *)(__bridge void *)layer + msgStrOffset);
                            id msgStr = (__bridge id)*msgStrPtr;
                            [mgr log:@"📐 messageString type: %@", NSStringFromClass([msgStr class])];
                            if (msgStr) {
                                // Dump iVars de messageString
                                unsigned int ic = 0;
                                Ivar *iv = class_copyIvarList([msgStr class], &ic);
                                [mgr log:@"📐 messageString iVars (%u):", ic];
                                for (unsigned int i = 0; i < ic; i++) {
                                    [mgr log:@"📐   %s", ivar_getName(iv[i])];
                                }
                                free(iv);
                                // Méthodes
                                unsigned int mc = 0;
                                Method *methods = class_copyMethodList([msgStr class], &mc);
                                [mgr log:@"📐 messageString méthodes (%u):", mc];
                                for (unsigned int i = 0; i < mc; i++) {
                                    [mgr log:@"📐   %@", NSStringFromSelector(method_getName(methods[i]))];
                                }
                                free(methods);
                            }
                        }
                    }
                }

                [mgr log:@"📐 ═══ FIN DUMP willDisplayCell ═══"];
            });

            method_setImplementation(origMethod, newIMP);
            [[SevenTVManager sharedManager] log:@"✅ willDisplayCell hooké sur ChatTranscriptView"];
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
