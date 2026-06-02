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
 *
 * CORRECTIF v1.1 — Swizzle WebSocket (Twitch 29.6)
 *   NSClassFromString(@"NSURLSessionWebSocketTask") retourne la classe ABSTRAITE.
 *   Twitch instancie une sous-classe concrète interne (ex: __NSCFURLSessionWebSocketTask).
 *   Fix: créer une instance-sonde WebSocket pour obtenir la vraie classe runtime,
 *   puis copier + échanger les méthodes sur cette classe concrète.
 *   Même pattern que le fix NSURLSession déjà validé.
 */

#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"

// ────────────────────────────────────────────────────────────
// MARK: - Helper swizzling
// ────────────────────────────────────────────────────────────

/*
 * s7tv_swizzle:
 * Copie la méthode `swizzled` depuis `sourceClass` vers `targetClass`
 * (si elle n'existe pas déjà sur targetClass), puis échange les
 * implémentations de `original` et `swizzled` sur `targetClass`.
 *
 * Pourquoi le paramètre sourceClass ?
 *   Les méthodes swizzlées sont définies dans des catégories sur les
 *   classes abstraites (NSURLSession, NSURLSessionWebSocketTask).
 *   Quand on veut swizzler une sous-classe concrète, ces méthodes
 *   n'existent pas encore dessus → il faut les y copier d'abord.
 */
static void s7tv_swizzle(Class targetClass,
                         Class sourceClass,
                         SEL   original,
                         SEL   swizzled) {
    if (!targetClass || !sourceClass) {
        [[SevenTVManager sharedManager] log:@"⚠️  swizzle ignoré (classe nil): %@",
         NSStringFromSelector(original)];
        return;
    }

    // Copier la méthode swizzlée depuis la classe source si nécessaire
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

    // Vérifier que la méthode originale existe sur la cible
    Method origMethod = class_getInstanceMethod(targetClass, original);
    if (!origMethod) {
        [[SevenTVManager sharedManager] log:@"⚠️  méthode originale introuvable sur %@: %@",
         NSStringFromClass(targetClass), NSStringFromSelector(original)];
        return;
    }

    // Re-récupérer la méthode swizzlée (maintenant sur targetClass)
    Method swizzledOnTarget = class_getInstanceMethod(targetClass, swizzled);
    method_exchangeImplementations(origMethod, swizzledOnTarget);

    [[SevenTVManager sharedManager] log:@"✅ swizzle OK [%@] %@",
     NSStringFromClass(targetClass), NSStringFromSelector(original)];
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
        // Après swizzle, appeler s7tv_ appelle en réalité l'original
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

            if (!error && message) {

                NSString *textToProcess = nil;

                if (message.type == NSURLSessionWebSocketMessageTypeString) {
                    // Cas normal : message texte IRC brut
                    textToProcess = message.string;

                } else if (message.type == NSURLSessionWebSocketMessageTypeData) {
                    // Fix 3 — Twitch peut envoyer des frames binaires.
                    // On tente une conversion UTF-8 directe (pas de décompression
                    // ici — si Twitch utilise permessage-deflate, NSURLSession
                    // le gère en amont et livre déjà du texte décompressé).
                    // Ce cas couvre surtout les messages IRC encodés en Data.
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
                    NSString *modified = [[SevenTVManager sharedManager]
                                          injectSevenTVEmotesIntoIRCMessage:textToProcess];

                    if (modified && ![modified isEqualToString:textToProcess]) {
                        NSURLSessionWebSocketMessage *newMsg =
                            [[NSURLSessionWebSocketMessage alloc] initWithString:modified];
                        completionHandler(newMsg, nil);
                        return;
                    }

                    // Pas d'emote mais le message est passé dans le hook → OK
                    // Si c'était un TypeData converti, on renvoie en String
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

    // Après swizzle, s7tv_ appelle l'original
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
            [[SevenTVManager sharedManager] log:@"📺 Rejoint le channel: %@", channel];
            [[SevenTVManager sharedManager] loadEmotesForChannelName:channel];
        }
    }

    // Toujours envoyer le message original sans modification
    [self s7tv_sendMessage:message completionHandler:completionHandler];
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Swizzle NSURLSession (classe concrète via sonde)
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle_session(void) {
    SEL swizzledSel = @selector(s7tv_dataTaskWithRequest:completionHandler:);
    SEL originalSel = @selector(dataTaskWithRequest:completionHandler:);

    // ── Session standard (sessionWithConfiguration:) ──
    NSURLSession *probeStd = [NSURLSession sessionWithConfiguration:
                              [NSURLSessionConfiguration defaultSessionConfiguration]];
    Class classStd = object_getClass(probeStd);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSession standard: %@",
     NSStringFromClass(classStd)];
    s7tv_swizzle(classStd, [NSURLSession class], originalSel, swizzledSel);

    // ── Fix 4 — sharedSession (classe potentiellement différente) ──
    // Twitch peut utiliser [NSURLSession sharedSession] pour ses requêtes GQL.
    Class classShared = object_getClass([NSURLSession sharedSession]);
    [[SevenTVManager sharedManager] log:@"🔍 NSURLSession shared: %@",
     NSStringFromClass(classShared)];
    if (classShared != classStd) {
        // Classe différente → swizzle séparé nécessaire
        s7tv_swizzle(classShared, [NSURLSession class], originalSel, swizzledSel);
    } else {
        [[SevenTVManager sharedManager] log:@"ℹ️  sharedSession même classe que standard, pas de swizzle supplémentaire"];
    }
}


// ────────────────────────────────────────────────────────────
// MARK: - Swizzle NSURLSessionWebSocketTask (classe concrète via sonde)
//
// CORRECTIF v1.1:
//   Avant (cassé) : NSClassFromString(@"NSURLSessionWebSocketTask")
//                   → retourne la classe abstraite, jamais instanciée par Twitch
//   Maintenant    : on crée une instance-sonde pour obtenir la vraie classe
//                   concrète utilisée au runtime, puis on swizzle celle-ci.
// ────────────────────────────────────────────────────────────

static void s7tv_swizzle_websocket(void) {
    Class wsAbstractClass = NSClassFromString(@"NSURLSessionWebSocketTask");
    if (!wsAbstractClass) {
        [[SevenTVManager sharedManager] log:@"⚠️  NSURLSessionWebSocketTask introuvable (iOS < 13?)"];
        return;
    }

    // Créer une session éphémère + une tâche WebSocket "sonde" vers une URL
    // quelconque — on ne la démarre pas, on veut juste son isa.
    // wss://irc-ws.chat.twitch.tv est cohérent avec le contexte.
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    // Désactiver le swizzle NSURLSession sur cette session interne pour éviter
    // une récursion si le hook session est déjà actif.
    NSURLSession *probeSession = [NSURLSession sessionWithConfiguration:cfg];
    NSURL *probeURL = [NSURL URLWithString:@"wss://irc-ws.chat.twitch.tv/irc"];

    NSURLSessionWebSocketTask *probeTask = [probeSession webSocketTaskWithURL:probeURL];
    Class realWSClass = object_getClass(probeTask);
    [probeTask cancel]; // On n'a pas besoin de la connecter

    [[SevenTVManager sharedManager] log:@"🔍 NSURLSessionWebSocketTask classe concrète: %@",
     NSStringFromClass(realWSClass)];

    // Si la classe concrète est différente de l'abstraite, loguer les deux
    if (realWSClass != wsAbstractClass) {
        [[SevenTVManager sharedManager] log:@"ℹ️  Classe abstraite: %@ → classe concrète: %@",
         NSStringFromClass(wsAbstractClass), NSStringFromClass(realWSClass)];
    }

    // Swizzle receiveMessageWithCompletionHandler:
    s7tv_swizzle(realWSClass,
                 wsAbstractClass,
                 @selector(receiveMessageWithCompletionHandler:),
                 @selector(s7tv_receiveMessageWithCompletionHandler:));

    // Swizzle sendMessage:completionHandler:
    s7tv_swizzle(realWSClass,
                 wsAbstractClass,
                 @selector(sendMessage:completionHandler:),
                 @selector(s7tv_sendMessage:completionHandler:));

    // Si realWSClass == wsAbstractClass (cas rare iOS < 16), les swizzles ci-dessus
    // couvrent quand même le cas: les sous-classes héritent de l'implémentation échangée.
}


// ────────────────────────────────────────────────────────────
// MARK: - Point d'entrée (remplace %ctor de Logos)
// ────────────────────────────────────────────────────────────
// __attribute__((constructor)) s'exécute automatiquement quand
// le dylib est chargé par dyld, avant main(). Pas besoin de Substrate.

__attribute__((constructor))
static void TwitchSevenTVInit(void) {
    // Pré-initialiser le log buffer AVANT les swizzles pour que
    // les messages de diagnostic soient capturés dès le départ.
    // sharedManager crée le buffer dans son init → appel suffisant.
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr log:@"🔌 Chargement TwitchSevenTV v1.1 (substrate-free)..."];

    // ── Swizzle NSURLSession (réponses GQL Twitch) ──
    s7tv_swizzle_session();

    // ── Swizzle NSURLSessionWebSocketTask (chat IRC) ──
    //    CORRECTIF: utilise une instance-sonde pour obtenir la classe concrète
    s7tv_swizzle_websocket();

    // ── Initialiser le gestionnaire 7TV sur le main thread ──
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SevenTVManager sharedManager] setup];
        [NSURLProtocol registerClass:[SevenTVURLProtocol class]];
        [[SevenTVManager sharedManager] log:@"✅ SevenTVManager prêt, URLProtocol enregistré"];

        // Ajouter le bouton flottant après 2s (UI Twitch pas encore prête au launch)
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                [[SevenTVManager sharedManager] addSettingsButton];
                [[SevenTVManager sharedManager] log:@"✅ Bouton 7TV ajouté"];
            }
        );
    });
}
