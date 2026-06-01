/*
 * TwitchSevenTV - 7TV Emotes for Twitch iOS
 * Version: 1.0.0
 *
 * COMMENT: Ce fichier est le cœur du tweak. Il "accroche" (hook) l'application
 * Twitch pour intercepter les messages du chat et les images d'emotes.
 *
 * HOW IT WORKS:
 * 1. Quand Twitch reçoit un message de chat via WebSocket IRC, on l'intercepte
 * 2. On cherche si le message contient des noms d'emotes 7TV connues
 * 3. On injecte les IDs d'emotes dans le message (format Twitch standard)
 * 4. Quand Twitch demande l'image de l'emote, on redirige vers le CDN de 7TV
 * 5. L'UI de Twitch affiche l'emote normalement = aucun conflit possible
 */

#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVSettingsController.h"
#import <UIKit/UIKit.h>

// ============================================================
// MACRO DE LOG - n'affiche rien par défaut (DEBUG=0)
// Pour activer les logs: modifier DEBUG à 1 dans SevenTVManager.h
// ============================================================
#define S7TV_LOG(fmt, ...) [[SevenTVManager sharedManager] log:(fmt), ##__VA_ARGS__]


// ============================================================
// HOOK 1: AppDelegate - Initialisation au lancement de l'app
// ============================================================
%hook AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    BOOL result = %orig; // Appel original - TOUJOURS appeler %orig en premier

    // Initialise le gestionnaire 7TV (charge les emotes globales)
    [[SevenTVManager sharedManager] setup];

    // Enregistre notre intercepteur d'URL pour rediriger les images 7TV
    [NSURLProtocol registerClass:[SevenTVURLProtocol class]];

    // Ajoute le bouton flottant des paramètres après un court délai
    // (pour s'assurer que l'UI de Twitch est prête)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[SevenTVManager sharedManager] addSettingsButton];
    });

    S7TV_LOG(@"✅ TwitchSevenTV chargé avec succès");
    return result;
}

%end


// ============================================================
// HOOK 2: NSURLSessionWebSocketTask - Interception du chat IRC
//
// Twitch utilise IRC over WebSocket pour le chat.
// Chaque message ressemble à:
//   @emotes=25:0-4;... :user!user@twitch.tv PRIVMSG #channel :Kappa hello
//   ↑ "emotes=25:0-4" = emote Kappa (ID 25) aux positions 0 à 4
//
// On intercepte les messages ENTRANTS pour y injecter les emotes 7TV.
// On intercepte les messages SORTANTS pour détecter quel channel on rejoint.
// ============================================================
%hook NSURLSessionWebSocketTask

// --- Messages ENTRANTS (chat qu'on reçoit) ---
- (void)receiveMessageWithCompletionHandler:
    (void (^)(NSURLSessionWebSocketMessage *, NSError *))completionHandler {

    void (^wrappedHandler)(NSURLSessionWebSocketMessage *, NSError *) =
        ^(NSURLSessionWebSocketMessage *message, NSError *error) {

        // On ne traite que les messages texte sans erreur
        if (!error && message && message.type == NSURLSessionWebSocketMessageTypeString) {

            NSString *original = message.string;
            NSString *modified = [[SevenTVManager sharedManager]
                                  injectSevenTVEmotesIntoIRCMessage:original];

            // Si on a modifié le message, on crée un nouveau message
            if (modified && ![modified isEqualToString:original]) {
                S7TV_LOG(@"💬 Emotes 7TV injectées dans: %@", original);
                NSURLSessionWebSocketMessage *newMsg =
                    [[NSURLSessionWebSocketMessage alloc] initWithString:modified];
                completionHandler(newMsg, error);
                return;
            }
        }
        completionHandler(message, error);
    };
    %orig(wrappedHandler);
}

// --- Messages SORTANTS (ce qu'on envoie au serveur) ---
- (void)sendMessage:(NSURLSessionWebSocketMessage *)message
  completionHandler:(void (^)(NSError *))completionHandler {

    if (message.type == NSURLSessionWebSocketMessageTypeString) {
        NSString *text = message.string;

        // Détecter "JOIN #nom_du_channel" pour charger les emotes du channel
        if ([text hasPrefix:@"JOIN #"]) {
            NSString *channel = [[text substringFromIndex:6]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            S7TV_LOG(@"📺 Rejoint le channel: %@", channel);
            [[SevenTVManager sharedManager] loadEmotesForChannelName:channel];
        }
    }
    %orig; // Toujours envoyer le message original sans modification
}

%end


// ============================================================
// HOOK 3: NSURLSession dataTask - Interception des réponses API Twitch
//
// But: extraire l'ID numérique du broadcaster depuis les réponses GQL
// de Twitch, pour pouvoir appeler l'API 7TV qui nécessite cet ID.
// ============================================================
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *,
                                                       NSURLResponse *,
                                                       NSError *))completionHandler {

    NSString *host = request.URL.host ?: @"";

    // On ne touche qu'aux requêtes vers l'API GraphQL de Twitch
    if ([host isEqualToString:@"gql.twitch.tv"] && completionHandler) {

        void (^wrappedGQLHandler)(NSData *, NSURLResponse *, NSError *) =
            ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data && !error) {
                [[SevenTVManager sharedManager]
                    extractAndLoadEmotesFromGQLResponse:data];
            }
            completionHandler(data, response, error);
        };
        return %orig(request, wrappedGQLHandler);
    }

    return %orig; // Pour tout le reste, comportement normal
}

%end
