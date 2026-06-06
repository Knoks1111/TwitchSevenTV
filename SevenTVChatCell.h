/*
 * SevenTVChatCell.h
 * Cellule UITableView pour le chat overlay custom 7TV.
 *
 * Affiche : [pseudo en couleur] suivi des segments (texte + emotes).
 * Les emotes sont affichées avec leur taille réelle adaptée (hauteur cible 28pt).
 * Les messages supprimés affichent "[message supprimé]" en gris italic.
 */

#import <UIKit/UIKit.h>
#import "SevenTVChatMessage.h"

extern NSString * const kSevenTVChatCellReuseID;

@interface SevenTVChatCell : UITableViewCell

// Configure la cellule avec un message. Doit être appelé sur le main thread.
- (void)configureWithMessage:(SevenTVChatMessage *)message;

@end
