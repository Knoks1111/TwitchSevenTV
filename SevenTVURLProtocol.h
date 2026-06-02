/*
 * SevenTVURLProtocol.h
 *
 * Ce fichier intercepte les requêtes HTTP que Twitch fait pour charger
 * les images des emotes. Quand Twitch demande une image avec un ID
 * commençant par "7tv_", on redirige vers le vrai CDN de 7TV.
 */

#import <Foundation/Foundation.h>

@interface SevenTVURLProtocol : NSURLProtocol

// Préchauffage TCP/TLS vers cdn.7tv.app au JOIN d'un channel.
+ (void)prewarmCDNConnection;

// Vérifie si l'image d'une emote est déjà dans le cache NSURLCache.
// Thread-safe. Retourne YES immédiatement si en cache, NO sinon.
+ (BOOL)isEmoteIDCached:(NSString *)emoteID;

// Télécharge l'image d'une emote dans NSURLCache sans passer par URLProtocol.
// completion est appelé quand l'image est en cache (ou après 1s de timeout).
// Si l'image est déjà en cache, completion est appelé immédiatement.
+ (void)prefetchEmoteID:(NSString *)emoteID completion:(void(^)(void))completion;

@end
