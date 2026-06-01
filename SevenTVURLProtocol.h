/*
 * SevenTVURLProtocol.h
 *
 * Ce fichier intercepte les requêtes HTTP que Twitch fait pour charger
 * les images des emotes. Quand Twitch demande une image avec un ID
 * commençant par "7tv_", on redirige vers le vrai CDN de 7TV.
 */

#import <Foundation/Foundation.h>

@interface SevenTVURLProtocol : NSURLProtocol
@end
