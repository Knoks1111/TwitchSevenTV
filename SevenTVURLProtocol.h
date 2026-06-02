/*
 * SevenTVURLProtocol.h
 *
 * Ce fichier intercepte les requêtes HTTP que Twitch fait pour charger
 * les images des emotes. Quand Twitch demande une image avec un ID
 * commençant par "7tv_", on redirige vers le vrai CDN de 7TV.
 */

#import <Foundation/Foundation.h>

@interface SevenTVURLProtocol : NSURLProtocol

// Appeler dès que les emotes sont chargées pour préchauffer la connexion
// TCP/TLS vers cdn.7tv.app — élimine le délai de 4-5s sur la 1ère emote.
+ (void)prewarmCDNConnection;

@end
