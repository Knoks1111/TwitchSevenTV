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
// MARK: - Hook NSTextAttachment — ratio correct pour les emotes 7TV
//
// Twitch crée ses NSTextAttachment avec des bounds carrés (taille emote Twitch native).
// On swizzle attachmentBoundsForTextContainer:... pour retourner les vraies
// dimensions proportionnelles quand l'image vient du CDN 7TV.
//
// Stratégie :
//   1. Si l'attachment a une image → calculer son ratio réel (w/h)
//   2. Hauteur cible = hauteur de la ligne de texte (proposedLineFragment.size.height)
//      plafonnée à 28pt (comme les emotes Twitch natives)
//   3. Largeur = hauteur × ratio
//   4. Si pas d'image → laisser Twitch gérer (appel original)
// ────────────────────────────────────────────────────────────

@interface NSTextAttachment (S7TVRatio)
- (CGRect)s7tv_attachmentBoundsForTextContainer:(NSTextContainer *)tc
                            proposedLineFragment:(CGRect)lineFrag
                                   glyphPosition:(CGPoint)pos
                                  characterIndex:(NSUInteger)charIdx;
@end

@implementation NSTextAttachment (S7TVRatio)

- (CGRect)s7tv_attachmentBoundsForTextContainer:(NSTextContainer *)tc
                            proposedLineFragment:(CGRect)lineFrag
                                   glyphPosition:(CGPoint)pos
                                  characterIndex:(NSUInteger)charIdx {

    UIImage *img = self.image;

    // Vérifier que l'image vient d'une emote 7TV
    // (fileWrapper est nil pour les emotes Twitch natives chargées via URLProtocol)
    // On détecte via le fileWrapper.filename ou via l'URL de la requête associée.
    // Méthode simple et fiable : vérifier si l'image a un ratio non-carré
    // ET si on a un fileWrapper avec un nom contenant "7tv_".
    BOOL is7TV = NO;
    if (self.fileWrapper.filename.length > 0) {
        is7TV = [self.fileWrapper.filename containsString:@"7tv_"];
    }
    // Fallback : si l'image est chargée depuis notre URLProtocol,
    // contents contient les données WebP → on peut vérifier la taille de l'image
    if (!is7TV && img) {
        // Heuristique : si le ratio est non-carré (> 1.1 ou < 0.9), c'est probablement une 7TV
        CGFloat ratio = img.size.height > 0 ? (img.size.width / img.size.height) : 1.0;
        // Emotes Twitch natives : toujours carrées (28×28).
        // Emotes 7TV : peuvent être rectangulaires.
        // On applique le fix ratio dans tous les cas si on a une image — ça ne casse pas les carrées.
        is7TV = YES; // Applique le ratio réel à toutes les emotes (carrées ou non)
    }

    if (is7TV && img && img.size.height > 0) {
        // Hauteur cible alignée sur la ligne de texte, max 28pt
        // Hauteur fixe 48pt — dépasse volontairement la ligne de texte,
        // ce qui est OK car Twitch a un grand espacement entre messages.
        CGFloat targetH = 48.0;
        CGFloat ratio   = img.size.width / img.size.height;
        CGFloat targetW = targetH * ratio;
        // Descent = (targetH - hauteur de la ligne) / 2 pour centrer verticalement
        // dans le gap entre messages. Si lineFrag.size.height est dispo on l'utilise,
        // sinon on estime la hauteur de police à ~17pt.
        CGFloat lineH   = lineFrag.size.height > 0 ? lineFrag.size.height : 17.0;
        CGFloat descent = (targetH - lineH) / 2.0;
        if (descent < 0) descent = 0;
        return CGRectMake(0, -descent, targetW, targetH);
    }

    // Pas une emote 7TV → comportement original Twitch
    return [self s7tv_attachmentBoundsForTextContainer:tc
                                   proposedLineFragment:lineFrag
                                          glyphPosition:pos
                                         characterIndex:charIdx];
}

@end

static void s7tv_swizzle_text_attachment(void) {
    s7tv_swizzle([NSTextAttachment class],
                 [NSTextAttachment class],
                 @selector(attachmentBoundsForTextContainer:proposedLineFragment:glyphPosition:characterIndex:),
                 @selector(s7tv_attachmentBoundsForTextContainer:proposedLineFragment:glyphPosition:characterIndex:));
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
                NSUInteger attCount = 0;
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

    // ── Swizzle NSTextAttachment (ratio correct pour emotes 7TV) ─────────────
    s7tv_swizzle_text_attachment();

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
            }
        );
    });
}
