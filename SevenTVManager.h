/*
 * SevenTVManager.h
 * Gestionnaire principal de tout ce qui concerne 7TV.
 * C'est un "singleton" = une seule instance existe dans toute l'app.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ============================================================
// CONFIGURATION - Modifie ces valeurs selon tes besoins
// ============================================================

// Mettre à 1 pour activer les logs de débogage dans la console
// (visible avec Console.app sur Mac ou via syslog)
#define S7TV_DEBUG 0

// Préfixe utilisé pour nos faux IDs d'emotes dans Twitch
// NE PAS MODIFIER - doit correspondre à SevenTVURLProtocol.m
#define S7TV_EMOTE_ID_PREFIX @"7tv_"

// URLs de l'API 7TV
#define S7TV_API_BASE        @"https://7tv.io/v3"
#define S7TV_CDN_BASE        @"https://cdn.7tv.app/emote"

// Nombre maximum de lignes conservées dans le buffer de logs in-app
#define S7TV_LOG_BUFFER_MAX  1000

// Nom de la notification postée quand une nouvelle ligne est ajoutée au buffer
// SevenTVLogsController écoute cette notification pour se rafraîchir.
extern NSString *const S7TVLogsDidUpdateNotification;


// ============================================================
// Structure d'une emote 7TV
// ============================================================
@interface SevenTVEmote : NSObject
@property (nonatomic, strong) NSString *emoteID;   // ID 7TV (ex: "63071bb9464de28875c52531")
@property (nonatomic, strong) NSString *emoteName;  // Nom (ex: "KEKW")
@property (nonatomic, assign) BOOL isAnimated;      // Si c'est un GIF/animé
// Dimensions 1x en points (extraites de data.host.files dans l'API 7TV).
// Correspondent à la taille d'affichage cible dans le chat.
// 0 si non disponibles (anciennes entrées cache sans dimensions).
@property (nonatomic, assign) NSInteger width;
@property (nonatomic, assign) NSInteger height;
@end


// ============================================================
// Interface principale du gestionnaire
// ============================================================
@interface SevenTVManager : NSObject

// Accès au singleton
+ (instancetype)sharedManager;

// --- Configuration ---
@property (nonatomic, assign) BOOL isEnabled;             // 7TV activé/désactivé
@property (nonatomic, assign) BOOL showAnimated;          // Afficher les emotes animées dans le chat
@property (nonatomic, assign) BOOL showPickerAnimations;  // Animer les emotes dans le picker (favoris seulement)
@property (nonatomic, assign) BOOL showFloatingButton;    // Afficher/masquer le bouton flottant 7TV
@property (nonatomic, assign) BOOL debugLogging;          // NSLog console activé
@property (nonatomic, assign) BOOL tapLogging;            // Logs des taps (indépendant de debugLogging)

// --- Données des emotes ---
// Dictionnaire: @{ "KEKW": SevenTVEmote*, "Pog": SevenTVEmote*, ... }
@property (nonatomic, strong) NSDictionary<NSString *, SevenTVEmote *> *globalEmotes;
@property (nonatomic, strong) NSDictionary<NSString *, SevenTVEmote *> *channelEmotes;
@property (nonatomic, strong) NSString *currentChannelName;
@property (nonatomic, strong) NSString *currentChannelTwitchID;

// File de dispatch protégeant globalEmotes/channelEmotes (concurrent).
// Utiliser dispatch_sync(mgr.emoteQueue, ^{ ... }) pour lire,
// dispatch_barrier_async(mgr.emoteQueue, ^{ ... }) pour écrire.
@property (nonatomic, strong, readonly) dispatch_queue_t emoteQueue;

// --- Initialisation ---
- (void)setup;

// --- Chargement des emotes ---
- (void)loadGlobalEmotes;
- (void)loadEmotesForChannelName:(NSString *)channelName;
- (void)loadEmotesForChannelTwitchID:(NSString *)twitchUserID;

// --- Injection IRC ---
// Détecte les emotes 7TV dans un message IRC et injecte le tag emotes=
- (NSString *)injectSevenTVEmotesIntoIRCMessage:(NSString *)rawIRCMessage;

// --- Extraction depuis réponses Twitch GQL ---
- (void)extractAndLoadEmotesFromGQLResponse:(NSData *)responseData;

// --- Accès aux emotes ---
// Retourne l'emote 7TV correspondant au nom, ou nil si pas trouvée
- (SevenTVEmote *)emoteForName:(NSString *)name;

// URL CDN pour une emote (taille 4x pour Retina)
- (NSURL *)cdnURLForEmote:(SevenTVEmote *)emote;

// --- UI ---
- (void)addSettingsButton;

// Affiche/masque le picker d'emotes 7TV au-dessus de la barre de saisie.
// chatInputView: la Twitch.ChatInputView (pour positionner le picker et insérer le nom).
- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView;

// Appelé par TweakSevenTV quand le stream se ferme (ChatInputView.window → nil).
// Nettoie le picker sans toucher au responder chain (UIKit crashe sans fenêtre).
- (void)cleanupPickerForStreamClose;

// --- Logs ---
// log: est TOUJOURS enregistré dans le buffer in-app (indépendamment de debugLogging).
// Si debugLogging == YES, la ligne est aussi envoyée à NSLog / Console.
- (void)log:(NSString *)format, ...;

// Retourne une copie de toutes les lignes du buffer (thread-safe)
- (NSArray<NSString *> *)allLogs;

// Vide le buffer de logs
- (void)clearLogs;

// --- Ratios emotes ---
// Dictionnaire { emoteID → ratio (width/height) } utilisé par willDisplayCell pour resize
- (NSMutableDictionary *)emoteRatios;

// --- Ring buffer emotes ordonnées ---
// Appelé depuis willDisplayCell pour récupérer la liste des SevenTVEmote*
// dans l'ordre du message correspondant au nombre d'emote layers détectés.
// Retourne nil si aucune séquence ne correspond.
// Thread-safe. Consomme (retire) l'entrée du ring buffer.
- (NSArray<SevenTVEmote *> *)popEmoteSequenceForCount:(NSUInteger)count;

@end
