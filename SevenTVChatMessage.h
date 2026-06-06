/*
 * SevenTVChatMessage.h
 * Modèle de données pour un message du chat custom 7TV.
 *
 * Un message est composé de segments : texte ou emote.
 * Chaque segment est un NSDictionary avec les clés :
 *   "type"  : @"text" ou @"emote"
 *   "value" : NSString (texte affiché ou nom de l'emote)
 *   "emoteID" : NSString (ID 7TV ou Twitch, pour les emotes)
 *   "width"   : NSNumber (largeur réelle en px, pour les emotes 7TV)
 *   "height"  : NSNumber (hauteur réelle en px, pour les emotes 7TV)
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface SevenTVChatMessage : NSObject

@property (nonatomic, strong) NSString  *messageId;       // tag id= de l'IRC
@property (nonatomic, strong) NSString  *username;        // display-name
@property (nonatomic, strong) UIColor   *usernameColor;   // couleur du pseudo
@property (nonatomic, strong) NSArray<NSDictionary *> *badges;   // badges (pas utilisés pour l'instant)
@property (nonatomic, strong) NSArray<NSDictionary *> *segments; // texte + emotes
@property (nonatomic, assign) BOOL       isDeleted;       // message supprimé (ban/timeout)

// Parse un message IRC brut → SevenTVChatMessage
// Retourne nil si le message n'est pas un PRIVMSG
+ (instancetype)messageFromIRCString:(NSString *)ircLine;

@end
