/*
 * SevenTVURLProtocol.h
 *
 * Ce fichier intercepte les requêtes HTTP que Twitch fait pour charger
 * les images des emotes. Quand Twitch demande une image avec un ID
 * commençant par "7tv_", on redirige vers le vrai CDN de 7TV.
 */

#import <Foundation/Foundation.h>

// Clé d'association (objc_setAssociatedObject) posée sur la NSData brute
// servie via didLoadData:, contenant l'emoteID 7TV (NSString) correspondant.
// Permet à TweakSevenTV.m de retrouver, au moment où Twitch décode cette
// donnée en UIImage (+imageWithData:), quel ratio appliquer — sans dépendre
// d'un pipeline de chargement d'image qu'on ne contrôle pas.
extern const char kS7TVEmoteIDOnDataKey;

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

// Cache partagé entre le chat (URLProtocol) et le picker.
// Utiliser ce cache dans SevenTVManager pour que les deux lisent/écrivent
// au même endroit — une emote vue dans le chat est immédiatement disponible
// dans le picker sans aucun réseau supplémentaire.
+ (NSURLCache *)sharedEmoteCache;

// Compteurs de conversion — nombre d'emotes converties en GIF animé
// et nombre d'emotes statiques servies en WebP depuis le démarrage.
// Utilisés par SevenTVManager pour le log bilan de fin de prefetch.
+ (NSInteger)gifConvertedCount;
+ (NSInteger)webpStaticCount;

@end
