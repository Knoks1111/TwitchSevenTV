/*
 * TweakSevenTV.m  —  Substrate-FREE version
 *
 * Remplace TweakSevenTV.xm (Logos/Substrate) par du pur
 * Objective-C runtime (method swizzling).
 * Aucune dépendance à CydiaSubstrate → fonctionne en sideload sans jailbreak.
 *
 * Mécanisme :
 *   1. __attribute__((constructor)) → s'exécute automatiquement au chargement du dylib
 *   2. method_exchangeImplementations → remplace les méthodes ciblées
 *   3. Catégories ObjC → contiennent les nouvelles implémentations
 */

#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"

// ────────────────────────────────────────────────────────────
// MARK: - Helper swizzling
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle(Class cls, SEL original, SEL swizzled) {
    if (!cls) { return; }
    Method origM  = class_getInstanceMethod(cls, original);
    Method swizzM = class_getInstanceMethod(cls, swizzled);
    if (!origM || !swizzM) {
        NSLog(@"[7TV] ⚠️  swizzle échoué: %@ → %@", NSStringFromSelector(original), NSStringFromSelector(swizzled));
        return;
    }
    method_exchangeImplementations(origM, swizzM);
    NSLog(@"[7TV] ✅ swizzle OK: %@", NSStringFromSelector(original));
}


// ────────────────────────────────────────────────────────────
// MARK: - Hook NSURLSession (réponses API GraphQL Twitch)
// ────────────────────────────────────────────────────────────

@interface NSURLSession (SevenTV)
- (NSURLSessionDataTask *)s7tv_dataTaskWithRequest:(NSURLRequest *)request
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
        // Appel de la méthode originale (les noms sont échangés après swizzle)
        return [self s7tv_dataTaskWithRequest:request completionHandler:wrappedHandler];
    }

    return [self s7tv_dataTaskWithRequest:request completionHandler:completionHandler];
}

@end


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

// Messages ENTRANTS : injecter les emotes 7TV dans les messages IRC
- (void)s7tv_receiveMessageWithCompletionHandler:
    (void (^)(NSURLSessionWebSocketMessage *, NSError *))completionHandler {

    void (^wrappedHandler)(NSURLSessionWebSocketMessage *, NSError *) =
        ^(NSURLSessionWebSocketMessage *message, NSError *error) {

            if (!error && message &&
                message.type == NSURLSessionWebSocketMessageTypeString) {

                NSString *original = message.string;
                NSString *modified = [[SevenTVManager sharedManager]
                                      injectSevenTVEmotesIntoIRCMessage:original];

                if (modified && ![modified isEqualToString:original]) {
                    NSURLSessionWebSocketMessage *newMsg =
                        [[NSURLSessionWebSocketMessage alloc] initWithString:modified];
                    completionHandler(newMsg, nil);
                    return;
                }
            }
            completionHandler(message, error);
        };

    // Après swizzle, appeler s7tv_ appelle en réalité l'original
    [self s7tv_receiveMessageWithCompletionHandler:wrappedHandler];
}

// Messages SORTANTS : détecter "JOIN #channel" pour charger les emotes
- (void)s7tv_sendMessage:(NSURLSessionWebSocketMessage *)message
       completionHandler:(void (^)(NSError *))completionHandler {

    if (message.type == NSURLSessionWebSocketMessageTypeString) {
        NSString *text = message.string;
        if ([text hasPrefix:@"JOIN #"]) {
            NSString *channel = [[text substringFromIndex:6]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSLog(@"[7TV] 📺 Rejoint le channel: %@", channel);
            [[SevenTVManager sharedManager] loadEmotesForChannelName:channel];
        }
    }

    // Toujours envoyer le message original sans modification
    [self s7tv_sendMessage:message completionHandler:completionHandler];
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Point d'entrée (remplace %ctor de Logos)
// ────────────────────────────────────────────────────────────
// __attribute__((constructor)) s'exécute automatiquement quand
// le dylib est chargé par dyld, avant main(). Pas besoin de Substrate.

__attribute__((constructor))
static void TwitchSevenTVInit(void) {
    NSLog(@"[7TV] 🔌 Chargement TwitchSevenTV (substrate-free)...");

    // ── Swizzle NSURLSession ──
    s7tv_swizzle(
        [NSURLSession class],
        @selector(dataTaskWithRequest:completionHandler:),
        @selector(s7tv_dataTaskWithRequest:completionHandler:)
    );

    // ── Swizzle NSURLSessionWebSocketTask ──
    Class wsClass = NSClassFromString(@"NSURLSessionWebSocketTask");
    if (wsClass) {
        s7tv_swizzle(wsClass,
            @selector(receiveMessageWithCompletionHandler:),
            @selector(s7tv_receiveMessageWithCompletionHandler:));
        s7tv_swizzle(wsClass,
            @selector(sendMessage:completionHandler:),
            @selector(s7tv_sendMessage:completionHandler:));
    } else {
        NSLog(@"[7TV] ⚠️  NSURLSessionWebSocketTask introuvable (iOS < 13 ?)");
    }

    // ── Initialiser le gestionnaire 7TV sur le main thread ──
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SevenTVManager sharedManager] setup];
        [NSURLProtocol registerClass:[SevenTVURLProtocol class]];
        NSLog(@"[7TV] ✅ SevenTVManager prêt, URLProtocol enregistré");

        // Ajouter le bouton flottant après 2s (UI Twitch pas encore prête au launch)
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [[SevenTVManager sharedManager] addSettingsButton];
                NSLog(@"[7TV] ✅ Bouton 7TV ajouté");
            }
        );
    });
}
