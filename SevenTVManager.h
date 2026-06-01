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

// ============================================================
// Structure d'une emote 7TV
// ============================================================
@interface SevenTVEmote : NSObject
@property (nonatomic, strong) NSString *emoteID;   // ID 7TV (ex: "63071bb9464de28875c52531")
@property (nonatomic, strong) NSString *emoteName;  // Nom (ex: "KEKW")
@property (nonatomic, assign) BOOL isAnimated;      // Si c'est un GIF/animé
@end


// ============================================================
// Interface principale du gestionnaire
// ============================================================
@interface SevenTVManager : NSObject

// Accès au singleton
+ (instancetype)sharedManager;

// --- Configuration ---
@property (nonatomic, assign) BOOL isEnabled;       // 7TV activé/désactivé
@property (nonatomic, assign) BOOL showAnimated;    // Afficher les emotes animées
@property (nonatomic, assign) BOOL debugLogging;    // Logs activés

// --- Données des emotes ---
// Dictionnaire: @{ "KEKW": SevenTVEmote*, "Pog": SevenTVEmote*, ... }
@property (nonatomic, strong) NSDictionary<NSString *, SevenTVEmote *> *globalEmotes;
@property (nonatomic, strong) NSDictionary<NSString *, SevenTVEmote *> *channelEmotes;
@property (nonatomic, strong) NSString *currentChannelName;
@property (nonatomic, strong) NSString *currentChannelTwitchID;

// --- Initialisation ---
- (void)setup;

// --- Chargement des emotes ---
- (void)loadGlobalEmotes;
- (void)loadEmotesForChannelName:(NSString *)channelName;
- (void)loadEmotesForChannelTwitchID:(NSString *)twitchUserID;

// --- Traitement des messages IRC ---
// Prend un message IRC Twitch brut et y injecte les tags d'emotes 7TV
// Retourne le message modifié (ou l'original si rien à changer)
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

// --- Logs ---
- (void)log:(NSString *)format, ...;

@end
