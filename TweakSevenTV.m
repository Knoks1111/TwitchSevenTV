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
#import <ImageIO/ImageIO.h>
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVLogo.h"
#import "SevenTVSettingsController.h"
#import "fishhook.h"
#import <CoreText/CoreText.h>


// ────────────────────────────────────────────────────────────
// MARK: - Clés associated objects (adresses uniques = clés)
// ────────────────────────────────────────────────────────────














// ────────────────────────────────────────────────────────────
// MARK: - Hijack du bouton Bits → bouton 7TV
//
// Stratégie (déduite des logs de diagnostic) :
//
//   Twitch.ChatInputView contient, dans un UIView container, ces boutons:
//     • Twitch.ChatInputViewBitsButton      accID='chat_input_bits_button'
//     • Twitch.ChatInputViewEmoticonButton  accID='chat_input_emoticon_button'
//     • TwitchCoreUI.MinimumHitAreaButton   accID='chat_settings_button'
//
//   On NE crée PAS de nouveau bouton. On RÉUTILISE ChatInputViewBitsButton :
//     1. Remplacer son image par l'icône 7TV sparkles + tint violet
//     2. Remplacer son accessibilityLabel par "7TV Emotes"
//     3. Retirer l'action originale (bitsButtonTapped) et brancher la nôtre
//     4. Stocker la référence à ChatInputView pour le picker
//
//   Avantages : position native, frame native, layout Twitch inchangé,
//   visible uniquement si Twitch décide de montrer le bouton Bits.
//
//   Fallback : si Bits introuvable (streamer sans Bits), on injecte
//   un bouton à gauche du bouton Emote comme avant.
//
// kS7TVTextFieldTagged : guard anti-doublon sur ChatInputView
// kS7TVBitsHijacked    : marqueur posé sur le ChatInputViewBitsButton hijacké
// ────────────────────────────────────────────────────────────

static const char kS7TVTextFieldTagged = 5;
static const char kS7TVBitsHijacked    = 6;

@interface UIView (S7TVChatInputHook)
- (void)s7tv_didMoveToWindow;
@end

@implementation UIView (S7TVChatInputHook)

- (void)s7tv_didMoveToWindow {
    [self s7tv_didMoveToWindow]; // appel original

    // Filtrer : seule Twitch.ChatInputView nous intéresse
    NSString *selfClass = NSStringFromClass([self class]);
    if (![selfClass isEqualToString:@"Twitch.ChatInputView"]) return;
    UIView *chatInputView = self;

    // Guard anti-doublon
    if (objc_getAssociatedObject(chatInputView, &kS7TVTextFieldTagged)) return;
    objc_setAssociatedObject(chatInputView, &kS7TVTextFieldTagged, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Attendre que le layout Twitch soit finalisé
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{

        SevenTVManager *mgr = [SevenTVManager sharedManager];

        // ── BFS : chercher ChatInputViewBitsButton ET EmoticonButton ─────────
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

        // ── CAS A : Bouton Bits trouvé → HIJACK ──────────────────────────────
        if (bitsBtn && ![objc_getAssociatedObject(bitsBtn, &kS7TVBitsHijacked) boolValue]) {

            // Marquer comme hijacké (guard re-entrée)
            objc_setAssociatedObject(bitsBtn, &kS7TVBitsHijacked, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            // 1. Retirer TOUTES les actions Twitch sur TouchUpInside
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

            // 2. Remplacer l'image par le vrai logo 7TV (PNG transparent, encodé en base64)
            NSData *logoData = [[NSData alloc]
                initWithBase64EncodedString:kS7TVLogoBase64
                                   options:NSDataBase64DecodingIgnoreUnknownCharacters];
            // scale:2.0 → le PNG fait 56 px = 28 pt @2x
            UIImage *icon7tv = [UIImage imageWithData:logoData scale:2.0];

            if (icon7tv) {
                // Redimensionner le logo pour correspondre à la taille du bouton Emote natif
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
                // Pas de tint forcé : l'image garde ses vraies couleurs holographiques
                bitsBtn.tintColor = [UIColor whiteColor];
            }

            // 3. Accessibilité
            bitsBtn.accessibilityLabel = @"7TV Emotes";

            // 4. Stocker la référence ChatInputView pour le picker
            objc_setAssociatedObject(bitsBtn, &kS7TVTextFieldTagged, chatInputView,
                                     OBJC_ASSOCIATION_ASSIGN);

            // 5. Brancher notre action
            [bitsBtn addTarget:mgr
                        action:@selector(s7tv_emoteButtonTappedForButton:)
              forControlEvents:UIControlEventTouchUpInside];

            [mgr log:@"✅ Bouton Bits hijacké → 7TV (frame=%.0f,%.0f,%.0f,%.0f)",
             bitsBtn.frame.origin.x, bitsBtn.frame.origin.y,
             bitsBtn.frame.size.width, bitsBtn.frame.size.height];

        // ── CAS B : Pas de bouton Bits → Fallback: injecter à gauche de Emote ─
        } else if (!bitsBtn) {

            [mgr log:@"⚠️ ChatInputViewBitsButton introuvable — fallback injection"];

            UIView *target = emoticonBtn.superview ?: chatInputView;

            // Guard anti-doublon sur le tag 0x7777
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
// MARK: - Hook CoreText CTRunDelegate via NSAttributedString
//
// DIAGNOSTIC CONFIRMÉ (logs) :
//   L1 et L2 se déclenchent bien → 28×28 stocké dans NSLayoutManager.
//   MAIS les emotes restent 18×18 à l'écran.
//   Raison : Twitch.MessageStringView (sub=0, pas de UITextView) utilise
//   CoreText DIRECT. Le rendu passe par CTFramesetterCreateWithAttributedString
//   + CTRunDelegate avec une callback C hardcodée à 18×18 — bypasse complètement
//   NSTextAttachment.attachmentBoundsForTextContainer: et NSLayoutManager.
//
// NOUVELLE STRATÉGIE — 2 couches CoreText :
//
//   Couche A — Hook NSAttributedString avant CoreText :
//     Swizzle -[NSAttributedString attribute:atIndex:effectiveRange:]
//     et -[NSMutableAttributedString addAttribute:value:range:].
//     Quand un NSTextAttachment est posé sur un caractère, on remplace
//     son bounds via la propriété `bounds` (CGRect) pour forcer 28×28.
//     NSTextAttachment.bounds est lue par CTRunDelegate si elle est non-zero.
//
//   Couche B — Hook CTFramesetterCreateWithAttributedString (C function) :
//     Impossible de swizzler les fonctions C CoreText directement sans fishhook.
//     À la place : hook -[UIView drawRect:] sur Twitch.MessageStringView
//     et patcher l'NSAttributedString passé à CoreText AVANT le draw.
//     Technique : swizzle -drawRect: sur la classe concrète Twitch,
//     remplacer chaque NSTextAttachment dans le textStorage par un
//     attachment avec bounds forcés à 28×28.
//
//   Couche C — NSTextAttachment.bounds direct :
//     Avant tout : forcer attachment.bounds = CGRectMake(0,-5,28,28)
//     dès la création. Le offset Y = -5 aligne verticalement l'emote
//     avec la baseline du texte (standard pour les inline images).
//     CTRunDelegate utilise bounds si non-zero → taille respectée.
// ────────────────────────────────────────────────────────────

#define S7TV_EMOTE_TARGET_SIZE 28.0
#define S7TV_TWITCH_HARDCODED  18.0

// ── Couche 1 : NSTextAttachment base (gardée pour TextKit 1 si présent) ──────

@interface NSTextAttachment (S7TVSize)
- (CGRect)s7tv_attachmentBoundsForTextContainer:(NSTextContainer *)tc
                            proposedLineFragment:(CGRect)lineFrag
                                   glyphPosition:(CGPoint)pos
                                  characterIndex:(NSUInteger)charIdx;
@end

@implementation NSTextAttachment (S7TVSize)

- (CGRect)s7tv_attachmentBoundsForTextContainer:(NSTextContainer *)tc
                            proposedLineFragment:(CGRect)lineFrag
                                   glyphPosition:(CGPoint)pos
                                  characterIndex:(NSUInteger)charIdx {

    CGRect orig = [self s7tv_attachmentBoundsForTextContainer:tc
                                          proposedLineFragment:lineFrag
                                                 glyphPosition:pos
                                                characterIndex:charIdx];

    if (fabs(orig.size.width  - S7TV_TWITCH_HARDCODED) < 1.0 &&
        fabs(orig.size.height - S7TV_TWITCH_HARDCODED) < 1.0) {
        return CGRectMake(0, -5, S7TV_EMOTE_TARGET_SIZE, S7TV_EMOTE_TARGET_SIZE);
    }
    if (orig.size.width < 1.0 && orig.size.height < 1.0) {
        return CGRectMake(0, -5, S7TV_EMOTE_TARGET_SIZE, S7TV_EMOTE_TARGET_SIZE);
    }
    return orig;
}

@end


// ── Couche 2 : NSLayoutManager (gardée pour TextKit 1 si présent) ────────────

@interface NSLayoutManager (S7TVAttachmentSize)
- (void)s7tv_setAttachmentSize:(CGSize)size forGlyphRange:(NSRange)glyphRange;
@end

@implementation NSLayoutManager (S7TVAttachmentSize)

- (void)s7tv_setAttachmentSize:(CGSize)size forGlyphRange:(NSRange)glyphRange {
    if (fabs(size.width  - S7TV_TWITCH_HARDCODED) < 1.0 &&
        fabs(size.height - S7TV_TWITCH_HARDCODED) < 1.0) {
        size = CGSizeMake(S7TV_EMOTE_TARGET_SIZE, S7TV_EMOTE_TARGET_SIZE);
    }
    [self s7tv_setAttachmentSize:size forGlyphRange:glyphRange];
}

@end

// ── Couche E : Hook CTRunDelegateCreate via fishhook ─────────────────────────
//
// DIAGNOSTIC CONFIRMÉ (logs TAP scan) :
//   Twitch.MessageStringView a sub=0 → AUCUNE UIImageView enfant.
//   Twitch dessine les emotes PUREMENT via CoreText CTRunDelegate.
//   Le hook setImage: ne se déclenche donc jamais pour les emotes chat.
//
// VRAIE STRATÉGIE :
//   CTRunDelegateCreate est appelé PAR TWITCH (dans sa PLT) → hookable fishhook.
//   On wrappe chaque CTRunDelegateCallbacks créé par Twitch :
//     - On stocke les callbacks originales de Twitch
//     - On substitue nos propres callbacks qui appellent l'original PUIS
//       retournent S7TV_EMOTE_TARGET_SIZE si la valeur originale ≈ 18
//
// Structure : on garde une table de callbacks wrappées (max 32 slots).
// ──────────────────────────────────────────────────────────────────────────────

// Table des callbacks originales interceptées (Twitch n'en crée que quelques-unes)
#define S7TV_MAX_DELEGATE_WRAPPERS 32

typedef struct {
    CTRunDelegateGetAscentCallback   origAscent;
    CTRunDelegateGetDescentCallback  origDescent;
    CTRunDelegateGetWidthCallback    origWidth;
    CTRunDelegateDeallocateCallback  origDealloc;
    BOOL                             used;
} S7TVDelegateWrapper;

static S7TVDelegateWrapper s_delegateWrappers[S7TV_MAX_DELEGATE_WRAPPERS];
static int s_wrapperCount = 0;
static BOOL s_ctrundelegatehook_logged = NO;

// ── Nos callbacks wrappées (une par slot) ────────────────────────────────────
// On génère 4 slots manuellement (Twitch n'a que 1-2 patterns d'emotes).
// Chaque slot a ses propres fonctions C statiques pour éviter les closures.

#define MAKE_DELEGATE_WRAPPER(IDX) \
static CGFloat s7tv_ascent_##IDX(void *ref) { \
    CGFloat v = s_delegateWrappers[IDX].origAscent \
        ? s_delegateWrappers[IDX].origAscent(ref) : 18.0f; \
    if (v >= 13.0f && v <= 22.0f) { \
        static int _cnt = 0; _cnt++; \
        if (_cnt <= 5 || (_cnt % 200) == 0) { \
            dispatch_async(dispatch_get_main_queue(), ^{ \
                [[SevenTVManager sharedManager] \
                    log:@"\U0001f3af CTRunDelegate[" #IDX "] ascent %.1f→%.1f (#%d)", \
                    v, (CGFloat)S7TV_EMOTE_TARGET_SIZE, _cnt]; \
            }); \
        } \
        return S7TV_EMOTE_TARGET_SIZE; \
    } \
    return v; \
} \
static CGFloat s7tv_descent_##IDX(void *ref) { \
    CGFloat v = s_delegateWrappers[IDX].origDescent \
        ? s_delegateWrappers[IDX].origDescent(ref) : 0.0f; \
    if (v >= 0.0f && v <= 8.0f) return 0.0f; \
    return v; \
} \
static CGFloat s7tv_width_##IDX(void *ref) { \
    CGFloat v = s_delegateWrappers[IDX].origWidth \
        ? s_delegateWrappers[IDX].origWidth(ref) : 18.0f; \
    if (v >= 13.0f && v <= 22.0f) return S7TV_EMOTE_TARGET_SIZE; \
    return v; \
} \
static void s7tv_dealloc_##IDX(void *ref) { \
    if (s_delegateWrappers[IDX].origDealloc) \
        s_delegateWrappers[IDX].origDealloc(ref); \
}

MAKE_DELEGATE_WRAPPER(0)
MAKE_DELEGATE_WRAPPER(1)
MAKE_DELEGATE_WRAPPER(2)
MAKE_DELEGATE_WRAPPER(3)
MAKE_DELEGATE_WRAPPER(4)
MAKE_DELEGATE_WRAPPER(5)
MAKE_DELEGATE_WRAPPER(6)
MAKE_DELEGATE_WRAPPER(7)

static CTRunDelegateGetAscentCallback  s_wrappedAscents[]  = { s7tv_ascent_0,  s7tv_ascent_1,  s7tv_ascent_2,  s7tv_ascent_3,  s7tv_ascent_4,  s7tv_ascent_5,  s7tv_ascent_6,  s7tv_ascent_7 };
static CTRunDelegateGetDescentCallback s_wrappedDescents[] = { s7tv_descent_0, s7tv_descent_1, s7tv_descent_2, s7tv_descent_3, s7tv_descent_4, s7tv_descent_5, s7tv_descent_6, s7tv_descent_7 };
static CTRunDelegateGetWidthCallback   s_wrappedWidths[]   = { s7tv_width_0,   s7tv_width_1,   s7tv_width_2,   s7tv_width_3,   s7tv_width_4,   s7tv_width_5,   s7tv_width_6,   s7tv_width_7 };
static CTRunDelegateDeallocateCallback s_wrappedDeallocs[] = { s7tv_dealloc_0, s7tv_dealloc_1, s7tv_dealloc_2, s7tv_dealloc_3, s7tv_dealloc_4, s7tv_dealloc_5, s7tv_dealloc_6, s7tv_dealloc_7 };

#define S7TV_ACTIVE_WRAPPERS 8

// ── Hook CTRunDelegateCreate ──────────────────────────────────────────────────

static CTRunDelegateRef (*orig_CTRunDelegateCreate)(const CTRunDelegateCallbacks *, void *) = NULL;

static CTRunDelegateRef s7tv_CTRunDelegateCreate(const CTRunDelegateCallbacks *callbacks,
                                                  void *refCon) {
    if (!callbacks) return orig_CTRunDelegateCreate(callbacks, refCon);

    // Tester si c'est un delegate "emote" : ascent ≈ 18 avec refCon nul
    // (on ne peut pas appeler les callbacks ici sans risque, on wrappe toujours
    //  les callbacks dont l'ascent hardcodé tombe dans [13, 22])
    // Chercher si ce pattern est déjà connu
    for (int i = 0; i < s_wrapperCount && i < S7TV_ACTIVE_WRAPPERS; i++) {
        if (s_delegateWrappers[i].origAscent  == callbacks->getAscent  &&
            s_delegateWrappers[i].origDescent == callbacks->getDescent &&
            s_delegateWrappers[i].origWidth   == callbacks->getWidth) {
            // Pattern déjà wrappé → utiliser ce slot
            CTRunDelegateCallbacks wrapped = {
                .version    = kCTRunDelegateVersion1,
                .dealloc    = s_wrappedDeallocs[i],
                .getAscent  = s_wrappedAscents[i],
                .getDescent = s_wrappedDescents[i],
                .getWidth   = s_wrappedWidths[i],
            };
            return orig_CTRunDelegateCreate(&wrapped, refCon);
        }
    }

    // Nouveau pattern → allouer un slot
    if (s_wrapperCount < S7TV_ACTIVE_WRAPPERS) {
        int idx = s_wrapperCount++;
        s_delegateWrappers[idx].origAscent  = callbacks->getAscent;
        s_delegateWrappers[idx].origDescent = callbacks->getDescent;
        s_delegateWrappers[idx].origWidth   = callbacks->getWidth;
        s_delegateWrappers[idx].origDealloc = callbacks->dealloc;
        s_delegateWrappers[idx].used        = YES;

        if (!s_ctrundelegatehook_logged) {
            s_ctrundelegatehook_logged = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[SevenTVManager sharedManager]
                    log:@"\U0001f3af CTRunDelegateCreate intercepté (slot %d) — wrapping callbacks", idx];
            });
        }

        CTRunDelegateCallbacks wrapped = {
            .version    = kCTRunDelegateVersion1,
            .dealloc    = s_wrappedDeallocs[idx],
            .getAscent  = s_wrappedAscents[idx],
            .getDescent = s_wrappedDescents[idx],
            .getWidth   = s_wrappedWidths[idx],
        };
        return orig_CTRunDelegateCreate(&wrapped, refCon);
    }

    // Slots épuisés → passer tel quel
    return orig_CTRunDelegateCreate(callbacks, refCon);
}


// ── Couche E bis : UIImageView setImage: (garde pour les badges futurs) ───────
// Les emotes chat n'ont pas de UIImageView (CoreText pur), mais on garde
// le hook pour les badges à gauche des pseudos (qui eux UTILISENT UIImageView).

@interface UIImageView (S7TVEmoteSize)
@end

@implementation UIImageView (S7TVEmoteSize)

- (void)s7tv_setImage:(UIImage *)image {
    [self s7tv_setImage:image];

    if (!image) return;

    CGRect f = self.frame;
    // Filtre rapide : seulement 18×18
    if (!(fabs(f.size.width  - S7TV_TWITCH_HARDCODED) < 0.5 &&
          fabs(f.size.height - S7TV_TWITCH_HARDCODED) < 0.5)) return;

    // Remonter la hiérarchie pour trouver le contexte (badge vs emote)
    UIView *ancestor = self.superview;
    BOOL inChat = NO;
    NSString *parentChain = @"";
    for (int i = 0; i < 6 && ancestor; i++) {
        NSString *cn = NSStringFromClass([ancestor class]);
        if (i < 3) parentChain = [parentChain stringByAppendingFormat:@"%@→", cn];
        if ([cn containsString:@"ChatMessage"] || [cn containsString:@"ChatReply"] ||
            [cn isEqualToString:@"Twitch.MessageStringView"]) {
            inChat = YES; break;
        }
        ancestor = ancestor.superview;
    }

    static NSInteger s_diagCount = 0;
    s_diagCount++;
    if (s_diagCount <= 5) {
        [[SevenTVManager sharedManager]
            log:@"\U0001f50d setImage 18x18 #%ld imgSize=(%.0fx%.0f) chain=%@ inChat=%@",
            (long)s_diagCount, image.size.width, image.size.height,
            parentChain, inChat ? @"OUI" : @"NON"];
    }

    if (!inChat) return;

    // Badge dans le chat → agrandir hitbox (même technique que les badges username)
    CGFloat cx = f.origin.x + f.size.width  / 2.0;
    CGFloat cy = f.origin.y + f.size.height / 2.0;
    self.frame = CGRectMake(cx - S7TV_EMOTE_TARGET_SIZE / 2.0,
                            cy - S7TV_EMOTE_TARGET_SIZE / 2.0,
                            S7TV_EMOTE_TARGET_SIZE,
                            S7TV_EMOTE_TARGET_SIZE);

    static NSInteger s_patchCount = 0;
    s_patchCount++;
    if (s_patchCount <= 10 || (s_patchCount % 100) == 0) {
        [[SevenTVManager sharedManager]
            log:@"\U0001f5bc setImage badge patch #%ld → 28×28", (long)s_patchCount];
    }
}

@end

static void s7tv_swizzle_imageview_frame(void) {
    s7tv_swizzle([UIImageView class],
                 [UIImageView class],
                 @selector(setImage:),
                 @selector(s7tv_setImage:));
}

static void s7tv_swizzle_layout_manager(void) {
    UITextView *probe = [[UITextView alloc] initWithFrame:CGRectZero];
    Class lmClass = object_getClass(probe.layoutManager);
    s7tv_swizzle(lmClass,
                 [NSLayoutManager class],
                 @selector(setAttachmentSize:forGlyphRange:),
                 @selector(s7tv_setAttachmentSize:forGlyphRange:));
}

static void s7tv_swizzle_text_attachment_subclasses(void) {
    SEL origSel = @selector(attachmentBoundsForTextContainer:proposedLineFragment:glyphPosition:characterIndex:);
    SEL swizSel = @selector(s7tv_attachmentBoundsForTextContainer:proposedLineFragment:glyphPosition:characterIndex:);

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (cls == [NSTextAttachment class]) continue;
        Class super = class_getSuperclass(cls);
        while (super) {
            if (super == [NSTextAttachment class]) {
                Method m     = class_getInstanceMethod(cls, origSel);
                Method baseM = class_getInstanceMethod([NSTextAttachment class], origSel);
                if (m && m != baseM) {
                    s7tv_swizzle(cls, [NSTextAttachment class], origSel, swizSel);
                }
                break;
            }
            super = class_getSuperclass(super);
        }
    }
    free(classes);
}

static void s7tv_swizzle_text_attachment(void) {
    s7tv_swizzle([NSTextAttachment class],
                 [NSTextAttachment class],
                 @selector(attachmentBoundsForTextContainer:proposedLineFragment:glyphPosition:characterIndex:),
                 @selector(s7tv_attachmentBoundsForTextContainer:proposedLineFragment:glyphPosition:characterIndex:));
    s7tv_swizzle_text_attachment_subclasses();
}


// ── Couche C : NSTextAttachment.bounds forcé à la pose de l'attribut ─────────
//
// Twitch.MessageStringView utilise CoreText direct.
// CTRunDelegate lit NSTextAttachment.bounds si non-zero.
// → On intercepte -[NSMutableAttributedString addAttribute:value:range:]
//   et -[NSTextStorage addAttribute:value:range:] pour forcer bounds=28×28
//   dès qu'un NSTextAttachment est posé.
//
// NSTextAttachment.bounds = CGRectMake(0, offset_y, w, h)
// offset_y négatif = décalage baseline. -5 est standard pour line height 20pt.

static void s7tv_fix_attachment_bounds(NSTextAttachment *att) {
    if (!att || ![att isKindOfClass:[NSTextAttachment class]]) return;
    CGRect b = att.bounds;
    // Si bounds sont déjà forcés par nous → ne pas boucler
    if (fabs(b.size.width - S7TV_EMOTE_TARGET_SIZE) < 0.5 &&
        fabs(b.size.height - S7TV_EMOTE_TARGET_SIZE) < 0.5) return;
    // Forcer si 0×0 ou 18×18 (les deux valeurs Twitch connues)
    if ((b.size.width < 1.0 && b.size.height < 1.0) ||
        (fabs(b.size.width  - S7TV_TWITCH_HARDCODED) < 1.0 &&
         fabs(b.size.height - S7TV_TWITCH_HARDCODED) < 1.0)) {
        att.bounds = CGRectMake(0, -5, S7TV_EMOTE_TARGET_SIZE, S7TV_EMOTE_TARGET_SIZE);
    }
}

@interface NSMutableAttributedString (S7TVBounds)
- (void)s7tv_addAttribute:(NSAttributedStringKey)name value:(id)value range:(NSRange)range;
- (void)s7tv_setAttributes:(NSDictionary<NSAttributedStringKey,id> *)attrs range:(NSRange)range;
@end

@implementation NSMutableAttributedString (S7TVBounds)

- (void)s7tv_addAttribute:(NSAttributedStringKey)name value:(id)value range:(NSRange)range {
    if ([name isEqualToString:NSAttachmentAttributeName]) {
        s7tv_fix_attachment_bounds((NSTextAttachment *)value);
    }
    [self s7tv_addAttribute:name value:value range:range];
}

- (void)s7tv_setAttributes:(NSDictionary<NSAttributedStringKey,id> *)attrs range:(NSRange)range {
    NSTextAttachment *att = attrs[NSAttachmentAttributeName];
    if (att) s7tv_fix_attachment_bounds(att);
    [self s7tv_setAttributes:attrs range:range];
}

@end


// ── Couche D : Hook Twitch.MessageStringView drawRect: ───────────────────────
//
// Dernière ligne de défense : juste avant que CoreText dessine,
// on parcourt le NSAttributedString de la vue et on force bounds
// sur tous les attachments encore à 18×18 ou 0×0.
// On ne peut pas accéder à l'attributedString interne de MessageStringView
// directement (classe Swift privée), donc on hook -drawRect: et on fait
// un scan de la couche CALayer pour détecter et patcher.
//
// En réalité : on hook -[UIView drawRect:] UNIQUEMENT sur
// Twitch.MessageStringView via IMP C attachée au runtime.
// La méthode appelle l'original puis ne fait rien d'autre — le vrai fix
// est en amont via la Couche C (addAttribute:).
// Ce hook sert surtout à confirmer que la vue dessine bien.

static IMP s_msgViewOrigDrawRect = NULL;

static void s7tv_imp_msgview_drawrect(id self, SEL _cmd, CGRect rect) {
    // Appeler l'original
    if (s_msgViewOrigDrawRect) {
        ((void (*)(id, SEL, CGRect))s_msgViewOrigDrawRect)(self, _cmd, rect);
    }
}

static void s7tv_swizzle_message_string_view(void) {
    // Retry avec délai car la classe Swift est chargée paresseusement
    void (^attempt)(void) = ^{
        Class cls = NSClassFromString(@"Twitch.MessageStringView");
        if (!cls) {
            [[SevenTVManager sharedManager]
                log:@"⚠️ Twitch.MessageStringView introuvable (sera retentée)"];
            return;
        }

        // Hook -setAttributedString: ou équivalent Swift si disponible
        // Chercher toutes les méthodes de la classe liées aux attributed strings
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        NSMutableArray *methodNames = [NSMutableArray array];
        for (unsigned int i = 0; i < methodCount; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name containsString:@"ttributed"] ||
                [name containsString:@"ttachment"] ||
                [name containsString:@"tring"] ||
                [name containsString:@"ize"] ||
                [name containsString:@"rame"]) {
                [methodNames addObject:name];
            }
        }
        free(methods);

        [[SevenTVManager sharedManager]
            log:@"🔍 MessageStringView méthodes pertinentes (%lu): %@",
            (unsigned long)methodNames.count,
            methodNames.count > 0 ? [methodNames componentsJoinedByString:@" | "] : @"(aucune)"];
    };

    attempt();
    // Retry à 3s pour les classes Swift chargées après le constructor
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), attempt);
}


// ── Swizzle NSMutableAttributedString (Couche C) ─────────────────────────────

static void s7tv_swizzle_attributed_string(void) {
    // Obtenir la classe concrète via sonde (peut être une sous-classe privée)
    NSMutableAttributedString *probe = [[NSMutableAttributedString alloc]
        initWithString:@"x"];
    Class cls = object_getClass(probe);
    [[SevenTVManager sharedManager]
        log:@"🔍 NSMutableAttributedString classe concrète: %@", NSStringFromClass(cls)];

    s7tv_swizzle(cls,
                 [NSMutableAttributedString class],
                 @selector(addAttribute:value:range:),
                 @selector(s7tv_addAttribute:value:range:));
    s7tv_swizzle(cls,
                 [NSMutableAttributedString class],
                 @selector(setAttributes:range:),
                 @selector(s7tv_setAttributes:range:));

    // Aussi swizzler NSTextStorage qui est une sous-classe fréquente
    Class tsClass = NSClassFromString(@"NSTextStorage");
    if (tsClass && tsClass != cls) {
        NSTextStorage *tsProbe = [[NSTextStorage alloc] initWithString:@"x"];
        Class tsConcreteClass = object_getClass(tsProbe);
        [[SevenTVManager sharedManager]
            log:@"🔍 NSTextStorage classe concrète: %@", NSStringFromClass(tsConcreteClass)];
        s7tv_swizzle(tsConcreteClass,
                     [NSMutableAttributedString class],
                     @selector(addAttribute:value:range:),
                     @selector(s7tv_addAttribute:value:range:));
        s7tv_swizzle(tsConcreteClass,
                     [NSMutableAttributedString class],
                     @selector(setAttributes:range:),
                     @selector(s7tv_setAttributes:range:));
    }
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
// MARK: - Tap Logger v2 — log détaillé de la hiérarchie au point touché
//
// À chaque tap dans l'app, on logue :
//   • Les coordonnées du tap
//   • La vue "hit" (hitTest) avec classe, frame, tag
//   • accessibilityLabel + accessibilityIdentifier
//   • Pour UIButton : titre de chaque état + nom de l'image
//   • Pour UITextField : placeholder
//   • Toute la chaîne de superviews (max 15 niveaux)
//   • Le UIViewController parent (le plus proche)
//
// ILLIMITÉ — pas de limite de taps.
// Peut être mis en pause/repris depuis SevenTVSettingsController.
// ────────────────────────────────────────────────────────────

// Contrôle depuis les paramètres 7TV (accessible via SevenTVManager)
// Défaut NO — SevenTVManager.init synchronise cette valeur avec la préférence sauvegardée.
BOOL s_tapLogEnabled = NO;
static NSInteger s_tapLogCount = 0;

// Helper : infos supplémentaires sur une vue pour le log
static NSString *s7tv_viewExtra(UIView *v) {
    NSMutableString *extra = [NSMutableString string];

    // accessibilityLabel
    if (v.accessibilityLabel.length > 0)
        [extra appendFormat:@" accLabel='%@'", v.accessibilityLabel];

    // accessibilityIdentifier
    if (v.accessibilityIdentifier.length > 0)
        [extra appendFormat:@" accID='%@'", v.accessibilityIdentifier];

    // UIButton : titre + nom image pour chaque état utile
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
            if (img) {
                // Essayer de récupérer le nom SF Symbol ou asset
                NSString *imgDesc = img.description;
                // description contient souvent "named(xxx)" ou les dimensions
                [extra appendFormat:@" btnImg[%@]=(%@)", stateNames[i], imgDesc];
            }
        }
        // Tag target/action
        NSSet *targets = [btn allTargets];
        for (id target in targets) {
            NSArray *actions = [btn actionsForTarget:target forControlEvent:UIControlEventTouchUpInside];
            if (actions.count > 0)
                [extra appendFormat:@" action=%@->%@",
                 NSStringFromClass([target class]), [actions componentsJoinedByString:@","]];
        }
    }

    // UITextField : placeholder
    if ([v isKindOfClass:[UITextField class]])
        [extra appendFormat:@" ph='%@'", ((UITextField *)v).placeholder ?: @""];

    // UILabel : texte court
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *txt = ((UILabel *)v).text;
        if (txt.length > 0 && txt.length <= 40)
            [extra appendFormat:@" text='%@'", txt];
    }

    return [extra copy];
}

// Helper : trouver le UIViewController responsable d'une vue
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

    // ── firstResponder actuel au moment du tap ────────────────────────────────
    // Permet de voir quel champ avait le focus AVANT que le tap change quoi que ce soit
    UIView *keyWindow = self;
    UIResponder *currentFR = nil;
    {
        // Parcourir la hiérarchie pour trouver le firstResponder
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

    // Vue touchée (hit)
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

    // ViewController parent le plus proche
    UIViewController *vc = s7tv_vcForView(hit);
    if (vc) {
        [mgr log:@"  VC: %@", NSStringFromClass([vc class])];
    }

    // Chaîne de superviews (max 15 niveaux)
    UIView *v = hit.superview;
    for (int d = 1; d <= 15 && v; d++, v = v.superview) {
        [mgr log:@"  [%02d] %@ frame=(%.0f,%.0f,%.0f,%.0f)%@",
         d, NSStringFromClass([v class]),
         v.frame.origin.x, v.frame.origin.y,
         v.frame.size.width, v.frame.size.height,
         s7tv_viewExtra(v)];
    }
    [mgr log:@"  ── fin hiérarchie ──"];

    // ── Scan deep centré sur le point tapé ───────────────────────────────────
    // But : identifier exactement quelle classe Twitch affiche les emotes dans
    // le chat et avec quelles dimensions, pour pouvoir hooker la bonne méthode.
    //
    // On cherche dans un rayon de 60pt autour du tap :
    //   • UIImageView  → candidat emote (frame, image size, classe parent)
    //   • UILabel      → texte du message (pour corréler avec l'emote)
    //   • NSTextAttachment dans tout UITextView trouvé (classe exacte + bounds)
    //   • Classes Twitch custom contenant "Chat" ou "Emote" ou "Message"

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{

        [mgr log:@"  🔍 SCAN CHAT @ (%.0f,%.0f) ──────────────", pt.x, pt.y];

        // Parcourir TOUTE la hiérarchie de la fenêtre
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

            // Ne garder que les vues proches du tap (rayon 80pt)
            if (dist > 80.0) continue;

            // ── UIImageView : candidat emote ──────────────────────────────────
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

            // ── UITextView : chercher NSTextAttachment ────────────────────────
            if ([sv isKindOfClass:[UITextView class]]) {
                UITextView *tv = (UITextView *)sv;
                NSAttributedString *attr = tv.attributedText;
                __block NSUInteger attCount = 0;
                if (attr.length > 0) {
                    [attr enumerateAttribute:NSAttachmentAttributeName
                                     inRange:NSMakeRange(0, attr.length)
                                     options:0
                                  usingBlock:^(id att, NSRange r, BOOL *stop) {
                        if (!att) return;
                        attCount++;
                        NSTextAttachment *ta = (NSTextAttachment *)att;
                        UIImage *img = ta.image;
                        // bounds retournés par la méthode standard
                        CGRect b = [ta attachmentBoundsForTextContainer:nil
                                                    proposedLineFragment:CGRectMake(0,0,320,20)
                                                           glyphPosition:CGPointZero
                                                          characterIndex:r.location];
                        [mgr log:@"  📎 Attachment[%lu] class=%@ imgSize=(%.0f×%.0f) bounds=(%.0f,%.0f,%.0f,%.0f)",
                         (unsigned long)attCount,
                         NSStringFromClass([att class]),
                         img ? img.size.width : 0, img ? img.size.height : 0,
                         b.origin.x, b.origin.y, b.size.width, b.size.height];
                    }];
                }
                [mgr log:@"  📝 UITextView(%@) frame=(%.0f,%.0f,%.0f,%.0f) attachments=%lu text='%.40@'",
                 cn,
                 frameInWindow.origin.x, frameInWindow.origin.y,
                 frameInWindow.size.width, frameInWindow.size.height,
                 (unsigned long)attCount,
                 tv.text ?: @""];
            }

            // ── Classes Twitch custom liées au chat / emotes ──────────────────
            BOOL isTwitchChat = [cn containsString:@"Chat"]
                             || [cn containsString:@"Emote"]
                             || [cn containsString:@"Message"]
                             || [cn containsString:@"Cell"]
                             || [cn containsString:@"Fragment"]
                             || [cn containsString:@"Token"];
            if (isTwitchChat) {
                [mgr log:@"  🎯 TWITCH(%@) frame=(%.0f,%.0f,%.0f,%.0f) sub=%lu",
                 cn,
                 frameInWindow.origin.x, frameInWindow.origin.y,
                 frameInWindow.size.width, frameInWindow.size.height,
                 (unsigned long)sv.subviews.count];
            }
        }
        [mgr log:@"  🔍 FIN SCAN (%ld vues inspectées)", (long)scanCount];
    });
}

@end

// ────────────────────────────────────────────────────────────
// MARK: - Hook AccountMenuViewController — section "7TV Settings"
//
// Injecte une nouvelle section tout en bas des paramètres Twitch
// natifs (_TtC6Twitch25AccountMenuViewController).
//
// Technique identique à TwitchDvnloader :
//   • numberOfSectionsInTableView: → orig + 1
//   • numberOfRowsInSection:       → 1 ligne dans notre section
//   • titleForHeaderInSection:     → nil (on utilise viewForHeaderInSection)
//   • viewForHeaderInSection:      → header avec logo 7TV + titre
//   • heightForHeaderInSection:    → 38pt
//   • cellForRowAtIndexPath:       → cellule disclosure native Twitch
//   • didSelectRowAtIndexPath:     → push SevenTVSettingsController
//
// On réutilise Twitch.SettingsDisclosureCell pour un rendu
// strictement identique aux autres lignes Twitch.
// ────────────────────────────────────────────────────────────

// ────────────────────────────────────────────────────────────
// MARK: - Swizzle AccountMenuViewController (100% runtime, pas de ref statique)
//
// On NE déclare PAS @interface _TtC6Twitch25AccountMenuViewController
// car la classe Swift n'existe pas au link-time → linker error.
// On crée une classe proxy S7TVAccountMenuProxy : NSObject dont on
// attache les IMPs sur la classe Twitch via class_addMethod au runtime.
// ────────────────────────────────────────────────────────────

// Clé pour stocker le nombre original de sections (associated object)
static const char kS7TVOrigSectionCount = 7;

// ── IMP implémentations (plain C, pas de category ObjC) ──────────────────

// ── Section 7TV = section 0 (EN TÊTE de liste) ───────────────────────────────
// La section 7TV est TOUJOURS la section 0.
// Les sections originales Twitch sont décalées : origIndex → origIndex + 1.
// kS7TVOrigSectionCount stocke le nombre de sections ORIGINAL (sans 7TV).

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

// Convertit un index de section affiché → index original Twitch (soustrait 1)
static NSInteger s7tv_origSection(NSInteger displayedSection) {
    return displayedSection - 1;
}

static NSInteger s7tv_imp_numberOfRows(id self, SEL _cmd, UITableView *tv, NSInteger section) {
    if (section == 0) return 1; // notre section 7TV
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

    // Header section 7TV — style identique aux headers natifs Twitch
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
        // Section Twitch originale → on décale l'index
        NSIndexPath *origIP = [NSIndexPath indexPathForRow:ip.row
                                                 inSection:s7tv_origSection(ip.section)];
        SEL origSel = NSSelectorFromString(@"s7tv_tableView:cellForRowAtIndexPath:");
        UITableViewCell *(*origIMP)(id, SEL, UITableView *, NSIndexPath *) =
            (UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))
            [self methodForSelector:origSel];
        return origIMP(self, origSel, tv, origIP);
    }

    // Notre cellule 7TV (section 0)
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
    cell.textLabel.numberOfLines = 0; // pas de troncature

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
        // Section Twitch originale → on décale l'index
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

// ────────────────────────────────────────────────────────────
// MARK: - Swizzle AccountMenuViewController
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle_account_menu(void) {
    Class target = NSClassFromString(@"_TtC6Twitch25AccountMenuViewController");
    if (!target) {
        [[SevenTVManager sharedManager]
            log:@"⚠️ _TtC6Twitch25AccountMenuViewController introuvable — swizzle ignoré"];
        return;
    }

    // Helper macro-like inline pour swizzler via IMP C pure (pas de catégorie statique)
    void (^swizzleWithIMP)(SEL, SEL, IMP, const char *) =
        ^(SEL origSel, SEL newSel, IMP newIMP, const char *types) {
            Method origMethod = class_getInstanceMethod(target, origSel);
            if (!origMethod) return;
            // Ajoute la nouvelle méthode (s7tv_*) sur la target
            class_addMethod(target, newSel, newIMP, types);
            // Récupère l'IMP fraîchement ajoutée
            Method newMethod = class_getInstanceMethod(target, newSel);
            if (newMethod) method_exchangeImplementations(origMethod, newMethod);
        };

    swizzleWithIMP(
        @selector(numberOfSectionsInTableView:),
        NSSelectorFromString(@"s7tv_numberOfSectionsInTableView:"),
        (IMP)s7tv_imp_numberOfSections,
        "q@:@"
    );
    swizzleWithIMP(
        @selector(tableView:numberOfRowsInSection:),
        NSSelectorFromString(@"s7tv_tableView:numberOfRowsInSection:"),
        (IMP)s7tv_imp_numberOfRows,
        "q@:@q"
    );
    swizzleWithIMP(
        @selector(tableView:titleForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:titleForHeaderInSection:"),
        (IMP)s7tv_imp_titleForHeader,
        "@@:@q"
    );
    swizzleWithIMP(
        @selector(tableView:viewForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:viewForHeaderInSection:"),
        (IMP)s7tv_imp_viewForHeader,
        "@@:@q"
    );
    swizzleWithIMP(
        @selector(tableView:heightForHeaderInSection:),
        NSSelectorFromString(@"s7tv_tableView:heightForHeaderInSection:"),
        (IMP)s7tv_imp_heightForHeader,
        "d@:@q"
    );
    swizzleWithIMP(
        @selector(tableView:cellForRowAtIndexPath:),
        NSSelectorFromString(@"s7tv_tableView:cellForRowAtIndexPath:"),
        (IMP)s7tv_imp_cellForRow,
        "@@:@@"
    );
    swizzleWithIMP(
        @selector(tableView:didSelectRowAtIndexPath:),
        NSSelectorFromString(@"s7tv_tableView:didSelectRowAtIndexPath:"),
        (IMP)s7tv_imp_didSelect,
        "v@:@@"
    );

    [[SevenTVManager sharedManager]
        log:@"✅ AccountMenuViewController swizzlé — section 7TV Settings injectée"];
}


// ── Couche D : Hook CTRunGetTypographicBounds via fishhook ────────────────────
//
// DIAGNOSTIC FINAL :
//   - fishhook CTRunDelegateCreate → jamais appelé depuis Twitch (appelé
//     en interne par CoreText → hors portée fishhook).
//   - fishhook CTFramesetterCreate → appelé mais pas d'attachments ObjC
//     (Twitch utilise CoreText pur, pas NSTextAttachment).
//
// VRAIE SOLUTION :
//   CTRunGetTypographicBounds est appelée DEPUIS TWITCH au moment du
//   layout pour lire les dimensions de chaque CTRun (ascent/descent/leading).
//   C'est dans la PLT de Twitch → hookable par fishhook.
//
//   Notre wrapper :
//     1. Appelle l'original → récupère ascent, descent, leading
//     2. Si ascent+descent ∈ [13, 21] (zone 18pt hardcodé ± marge) ET
//        que le run contient un kCTRunDelegateAttributeName (= c'est une
//        emote inline) → on force ascent=28, descent=0, leading=0
//     3. Retourne la largeur originale (CoreText gère width via CTRunDelegate)
//
//   On hook aussi CTLineGetTypographicBounds pour la hauteur de ligne globale.
//
// NOTE : on garde CTFramesetterCreate pour les paths NSTextAttachment résiduels.

static CGFloat (*orig_CTRunGetTypographicBounds)(CTRunRef, CFRange, CGFloat *, CGFloat *, CGFloat *) = NULL;
static CGFloat (*orig_CTLineGetTypographicBounds)(CTLineRef, CGFloat *, CGFloat *, CGFloat *) = NULL;
static CTFramesetterRef (*orig_CTFramesetterCreate)(CFAttributedStringRef, CFRange, CFDictionaryRef) = NULL;

static CGFloat s7tv_CTRunGetTypographicBounds(CTRunRef run,
                                               CFRange range,
                                               CGFloat *ascent,
                                               CGFloat *descent,
                                               CGFloat *leading) {
    CGFloat origAscent = 0, origDescent = 0, origLeading = 0;
    CGFloat width = orig_CTRunGetTypographicBounds(run, range,
                                                    &origAscent,
                                                    &origDescent,
                                                    &origLeading);

    // Détecter un run d'emote : ascent+descent correspond à ~18pt hardcodé
    // ET le run a un attribut CTRunDelegate (= c'est un attachment inline)
    BOOL isEmoteRun = NO;
    CGFloat total = origAscent + origDescent;

    // Log diagnostic : premiers runs avec CTRunDelegate (pour voir les vraies valeurs)
    CFDictionaryRef attrs = CTRunGetAttributes(run);
    if (attrs) {
        CFTypeRef delegate = CFDictionaryGetValue(attrs, kCTRunDelegateAttributeName);
        if (delegate != NULL) {
            static NSInteger s_runDiag = 0;
            s_runDiag++;
            if (s_runDiag <= 10) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[SevenTVManager sharedManager]
                        log:@"\U0001f50e CTRun delegate #%ld ascent=%.1f descent=%.1f total=%.1f width=%.1f",
                        (long)s_runDiag, origAscent, origDescent, total, width];
                });
            }
            // Élargir la plage : couvrir 13-30pt au lieu de 13-21pt
            if (total >= 10.0 && total <= 30.0) {
                isEmoteRun = YES;
            }
        }
    }

    if (isEmoteRun) {
        static NSInteger s_count = 0;
        s_count++;
        if (s_count <= 15 || (s_count % 300) == 0) {
            [[SevenTVManager sharedManager]
                log:@"\U0001f3af CTRun patch #%ld ascent=%.1f+%.1f → %.1f+0",
                (long)s_count, origAscent, origDescent, (CGFloat)S7TV_EMOTE_TARGET_SIZE];
        }
        if (ascent)  *ascent  = S7TV_EMOTE_TARGET_SIZE;
        if (descent) *descent = 0.0;
        if (leading) *leading = 0.0;
        // Retourner aussi la largeur à la bonne taille
        return S7TV_EMOTE_TARGET_SIZE;
    }

    if (ascent)  *ascent  = origAscent;
    if (descent) *descent = origDescent;
    if (leading) *leading = origLeading;
    return width;
}

static CGFloat s7tv_CTLineGetTypographicBounds(CTLineRef line,
                                                CGFloat *ascent,
                                                CGFloat *descent,
                                                CGFloat *leading) {
    CGFloat origAscent = 0, origDescent = 0, origLeading = 0;
    CGFloat width = orig_CTLineGetTypographicBounds(line, &origAscent, &origDescent, &origLeading);

    // Si la ligne contient au moins un run d'emote (ascent ~18),
    // on s'assure que la hauteur de ligne globale est au moins 28pt
    if (origAscent >= 13.0 && origAscent <= 21.0) {
        // Vérifier si la ligne contient un run avec CTRunDelegate
        CFArrayRef runs = CTLineGetGlyphRuns(line);
        if (runs) {
            CFIndex runCount = CFArrayGetCount(runs);
            for (CFIndex i = 0; i < runCount; i++) {
                CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, i);
                CFDictionaryRef attrs = CTRunGetAttributes(run);
                if (attrs && CFDictionaryGetValue(attrs, kCTRunDelegateAttributeName)) {
                    if (ascent)  *ascent  = S7TV_EMOTE_TARGET_SIZE;
                    if (descent) *descent = 0.0;
                    if (leading) *leading = 0.0;
                    return width;
                }
            }
        }
    }

    if (ascent)  *ascent  = origAscent;
    if (descent) *descent = origDescent;
    if (leading) *leading = origLeading;
    return width;
}

static CTFramesetterRef s7tv_CTFramesetterCreate(CFAttributedStringRef string,
                                                   CFRange stringRange,
                                                   CFDictionaryRef frameAttributes) {
    // Patcher les NSTextAttachment résiduels (path TextKit / non-CoreText pur)
    NSAttributedString *attrStr = (__bridge NSAttributedString *)string;
    NSUInteger len = attrStr.length;
    if (len > 0) {
        static NSInteger s_ftCount = 0;
        NSRange searchRange = NSMakeRange(0, len);
        while (searchRange.location < len) {
            NSRange effectiveRange;
            id val = [attrStr attribute:NSAttachmentAttributeName
                                atIndex:searchRange.location
                         effectiveRange:&effectiveRange];
            if (val && [val isKindOfClass:[NSTextAttachment class]]) {
                NSTextAttachment *att = (NSTextAttachment *)val;
                CGRect b = att.bounds;
                if (!(fabs(b.size.width  - S7TV_EMOTE_TARGET_SIZE) < 0.5 &&
                      fabs(b.size.height - S7TV_EMOTE_TARGET_SIZE) < 0.5)) {
                    s_ftCount++;
                    if (s_ftCount <= 10) {
                        [[SevenTVManager sharedManager]
                            log:@"\U0001f4ce CTFramesetter attach patch #%ld (%.1f\u00d7%.1f)",
                            (long)s_ftCount, b.size.width, b.size.height];
                    }
                    att.bounds = CGRectMake(0, -5, S7TV_EMOTE_TARGET_SIZE, S7TV_EMOTE_TARGET_SIZE);
                }
            }
            NSUInteger nextLoc = effectiveRange.location + effectiveRange.length;
            if (nextLoc <= searchRange.location) break;
            searchRange = NSMakeRange(nextLoc, len - nextLoc);
        }
    }
    return orig_CTFramesetterCreate(string, stringRange, frameAttributes);
}

static void s7tv_hook_coretext_framesetter(void) {
    struct rebinding bindings[] = {
        { "CTRunGetTypographicBounds",
          s7tv_CTRunGetTypographicBounds,
          (void **)&orig_CTRunGetTypographicBounds },
        { "CTLineGetTypographicBounds",
          s7tv_CTLineGetTypographicBounds,
          (void **)&orig_CTLineGetTypographicBounds },
        { "CTFramesetterCreateWithAttributedString",
          s7tv_CTFramesetterCreate,
          (void **)&orig_CTFramesetterCreate },
        { "CTRunDelegateCreate",
          s7tv_CTRunDelegateCreate,
          (void **)&orig_CTRunDelegateCreate },
    };
    int result = rebind_symbols(bindings, 4);
    [[SevenTVManager sharedManager]
        log:@"%@ fishhook CTRun/CTLine/CTFramesetter/CTRunDelegateCreate (result=%d)",
        result == 0 ? @"\u2705" : @"\u274c", result];
}


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

    // ── Swizzle NSTextAttachment (couches 1+2 TextKit 1, belt-and-suspenders) ─
    s7tv_swizzle_text_attachment();

    // ── Swizzle NSLayoutManager setAttachmentSize: (TextKit 1) ────────────────
    s7tv_swizzle_layout_manager();

    // ── Couche C : NSMutableAttributedString (belt-and-suspenders) ─────────────
    s7tv_swizzle_attributed_string();

    // ── Couche D : fishhook CoreText ──────────────────────────────────────────
    s7tv_hook_coretext_framesetter();

    // ── Couche E : UIImageView setFrame: 18×18→28×28 dans MessageStringView ──
    // Twitch place une UIImageView réelle à 18×18 pour chaque emote inline.
    // CoreText gère seulement l'espace réservé ; l'image est une vue UIKit séparée.
    s7tv_swizzle_imageview_frame();

    // ── Fix B: protocolClasses swizzle (avant la création de sessions) ────────
    s7tv_swizzle_protocol_classes();

    // ── Swizzle NSURLSession (réponses GQL Twitch) ────────────────────────────
    s7tv_swizzle_session();

    // ── Swizzle NSURLSessionWebSocketTask (chat IRC) ──────────────────────────
    s7tv_swizzle_websocket();

    // ── Swizzle AccountMenuViewController (section 7TV Settings dans les paramètres Twitch) ──
    s7tv_swizzle_account_menu();

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

                // Retry couche 3 : classes Swift souvent enregistrées après le constructor
                s7tv_swizzle_text_attachment_subclasses();

                // Découverte des méthodes Twitch.MessageStringView (diagnostic)
                s7tv_swizzle_message_string_view();
            }
        );
    });
}
