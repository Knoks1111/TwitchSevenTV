/*
 * SevenTVLogsController.h
 *
 * Écran de visualisation des logs 7TV en temps réel.
 * Accessible depuis SevenTVSettingsController → section Débogage → "Voir les logs".
 *
 * Fonctionnalités:
 *   - UITextView scrollable avec police monospace (lisibilité)
 *   - Se rafraîchit automatiquement via S7TVLogsDidUpdateNotification
 *   - Bouton "Copier tout" → copie tous les logs dans le presse-papier
 *   - Bouton "Effacer" → vide le buffer
 *   - Scroll automatique vers le bas à chaque nouvelle ligne
 *   - Badge en temps réel: nombre de lignes
 */

#import <UIKit/UIKit.h>

@interface SevenTVLogsController : UIViewController
@end
