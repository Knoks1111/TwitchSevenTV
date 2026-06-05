/*
 * SevenTVSettingsController.h
 * Écran de paramètres 7TV présenté dans un modal natif iOS.
 */

#import <UIKit/UIKit.h>

@interface SevenTVSettingsController : UITableViewController

// YES quand le VC est présenté en modal (via le bouton flottant 7TV).
// NO quand il est push depuis les paramètres Twitch natifs.
// Contrôle l'affichage du bouton "Fermer" dans la nav bar.
@property (nonatomic, assign) BOOL openedAsModal;

@end
