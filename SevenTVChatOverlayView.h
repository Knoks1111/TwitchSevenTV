/*
 * SevenTVChatOverlayView.h
 *
 * UIView container qui affiche le chat custom 7TV par-dessus le chat natif Twitch.
 * - UITableView self-sizing cells (auto scroll vers le bas)
 * - Pause auto-scroll si l'utilisateur scroll manuellement vers le haut
 * - Reprise auto-scroll si retour en bas
 * - Maximum 200 messages en mémoire
 * - Écoute les messages IRC depuis la notification "S7TVNewChatMessage"
 * - Écoute CLEARCHAT/CLEARMSG depuis "S7TVChatClear" et "S7TVChatDeleteMessage"
 */

#import <UIKit/UIKit.h>
#import "SevenTVChatMessage.h"

@interface SevenTVChatOverlayView : UIView

// Ajoute un message au chat (thread-safe, dispatch sur main)
- (void)addMessage:(SevenTVChatMessage *)message;

// Supprime tous les messages d'un pseudo (CLEARCHAT)
- (void)clearMessagesForUser:(NSString *)username;

// Supprime un message par ID (CLEARMSG)
- (void)deleteMessageWithID:(NSString *)messageId;

@end
