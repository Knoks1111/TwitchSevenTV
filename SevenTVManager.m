/*
 * SevenTVManager.m
 * Implémentation du gestionnaire 7TV.
 *
 * Ce fichier gère:
 * - Les appels API vers 7tv.io pour récupérer les emotes
 * - La mise en cache des emotes (pour ne pas re-télécharger à chaque fois)
 * - L'injection des emotes dans les messages IRC de Twitch
 * - La détection du broadcaster ID via les réponses GQL
 * - Le buffer de logs in-app (visible dans SevenTVLogsController)
 */

#import "SevenTVManager.h"
#import "SevenTVSettingsController.h"
#import <objc/runtime.h>

// ============================================================
// Constante de notification (définie ici, déclarée dans .h)
// ============================================================
NSString *const S7TVLogsDidUpdateNotification = @"S7TVLogsDidUpdateNotification";


// ============================================================
// Implémentation de SevenTVEmote
// ============================================================
@implementation SevenTVEmote
@end


// ============================================================
// SevenTVManager (privé)
// ============================================================
@interface SevenTVManager ()
// Ensemble des channel IDs déjà chargés (pour éviter les doublons)
@property (nonatomic, strong) NSMutableSet<NSString *> *loadedChannelIDs;
// File de dispatch pour la thread-safety des données d'emotes
@property (nonatomic, strong) dispatch_queue_t emoteQueue;
// Bouton flottant des paramètres
@property (nonatomic, weak) UIButton *settingsButton;

// ── Buffer de logs in-app ──────────────────────────────────
// Accès protégé par _logLock (NSLock simple, suffisant ici).
// On évite volontairement dispatch_queue pour ne pas risquer
// un deadlock si log: est appelé depuis l'emoteQueue.
@property (nonatomic, strong) NSMutableArray<NSString *> *logBuffer;
@property (nonatomic, strong) NSLock *logLock;
@end


@implementation SevenTVManager

// ============================================================
// Singleton
// ============================================================
+ (instancetype)sharedManager {
    static SevenTVManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SevenTVManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isEnabled    = YES;  // Activé par défaut
        _showAnimated = YES;  // Emotes animées activées par défaut
        _debugLogging = (S7TV_DEBUG == 1);

        _globalEmotes  = @{};
        _channelEmotes = @{};
        _loadedChannelIDs = [NSMutableSet set];
        _emoteQueue = dispatch_queue_create("tv.s7tv.emote-queue",
                                            DISPATCH_QUEUE_CONCURRENT);

        // Buffer de logs
        _logBuffer = [NSMutableArray arrayWithCapacity:256];
        _logLock   = [[NSLock alloc] init];

        // Charger les préférences sauvegardées
        [self loadPreferences];
    }
    return self;
}


// ============================================================
// MARK: - Cache disque (NSUserDefaults)
//
// Sérialise les emotes en plist pour un chargement instantané au démarrage.
// Clés: s7tv_cache_global  /  s7tv_cache_ch_{channelID}
// Format valeur: { "KEKW": { "id": "...", "a": 1 }, ... }
// ============================================================

static NSString *const kCacheGlobal = @"s7tv_cache_global";

- (void)saveEmotesToCache:(NSDictionary<NSString *, SevenTVEmote *> *)emotes
                   forKey:(NSString *)key {
    if (!emotes.count || !key) return;
    NSMutableDictionary *serial = [NSMutableDictionary dictionaryWithCapacity:emotes.count];
    for (NSString *name in emotes) {
        SevenTVEmote *e = emotes[name];
        serial[name] = @{ @"id": e.emoteID, @"a": @(e.isAnimated) };
    }
    [[NSUserDefaults standardUserDefaults] setObject:[serial copy] forKey:key];
}

- (NSDictionary<NSString *, SevenTVEmote *> *)loadEmotesFromCacheForKey:(NSString *)key {
    NSDictionary *serial = [[NSUserDefaults standardUserDefaults] dictionaryForKey:key];
    if (!serial.count) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:serial.count];
    for (NSString *name in serial) {
        NSDictionary *d = serial[name];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        SevenTVEmote *e = [[SevenTVEmote alloc] init];
        e.emoteName  = name;
        e.emoteID    = d[@"id"];
        e.isAnimated = [d[@"a"] boolValue];
        if (e.emoteID.length) result[name] = e;
    }
    return result.count ? [result copy] : nil;
}


// ============================================================
// MARK: - Initialisation
// ============================================================

- (void)setup {
    [self log:@"SevenTVManager: setup démarré"];

    // Charger le cache disque en premier (instantané, avant toute requête réseau)
    NSDictionary *cachedGlobal = [self loadEmotesFromCacheForKey:kCacheGlobal];
    if (cachedGlobal.count) {
        dispatch_barrier_async(self.emoteQueue, ^{
            self.globalEmotes = cachedGlobal;
        });
        [self log:@"⚡️ %lu emotes globales depuis cache disque", (unsigned long)cachedGlobal.count];
    }

    // Rafraîchir depuis l'API en arrière-plan
    [self loadGlobalEmotes];
}


// ============================================================
// MARK: - Préférences utilisateur (sauvegardées entre les sessions)
// ============================================================

- (void)loadPreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

    // Si la clé n'existe pas encore, on garde les valeurs par défaut
    if ([prefs objectForKey:@"s7tv_enabled"] != nil) {
        _isEnabled = [prefs boolForKey:@"s7tv_enabled"];
    }
    if ([prefs objectForKey:@"s7tv_animated"] != nil) {
        _showAnimated = [prefs boolForKey:@"s7tv_animated"];
    }
    if ([prefs objectForKey:@"s7tv_debug"] != nil) {
        _debugLogging = [prefs boolForKey:@"s7tv_debug"];
    }
}

- (void)savePreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setBool:self.isEnabled    forKey:@"s7tv_enabled"];
    [prefs setBool:self.showAnimated forKey:@"s7tv_animated"];
    [prefs setBool:self.debugLogging forKey:@"s7tv_debug"];
    [prefs synchronize];
}

// Appelé depuis SevenTVSettingsController quand l'utilisateur change un réglage
- (void)setIsEnabled:(BOOL)isEnabled {
    _isEnabled = isEnabled;
    [self savePreferences];
}
- (void)setShowAnimated:(BOOL)showAnimated {
    _showAnimated = showAnimated;
    [self savePreferences];
}
- (void)setDebugLogging:(BOOL)debugLogging {
    _debugLogging = debugLogging;
    [self savePreferences];
}


// ============================================================
// MARK: - Chargement des emotes globales 7TV
// API: GET https://7tv.io/v3/emote-sets/global
// ============================================================

- (void)loadGlobalEmotes {
    [self log:@"Chargement des emotes globales 7TV..."];

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/emote-sets/global", S7TV_API_BASE]];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    [[session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        if (error || !data) {
            [self log:@"❌ Erreur chargement emotes globales: %@", error.localizedDescription];
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                             options:0
                                                               error:nil];
        if (!json) {
            [self log:@"❌ JSON invalide pour les emotes globales"];
            return;
        }

        NSDictionary *parsed = [self parseEmoteSetJSON:json];
        dispatch_barrier_async(self.emoteQueue, ^{
            self.globalEmotes = parsed;
            [self log:@"✅ %lu emotes globales 7TV chargées", (unsigned long)parsed.count];
            // Sauvegarder dans le cache disque pour le prochain lancement
            [self saveEmotesToCache:parsed forKey:kCacheGlobal];
        });

    }] resume];
}


// ============================================================
// MARK: - Chargement des emotes d'un channel par nom
// On tente d'abord de retrouver l'ID Twitch via nos données mémorisées
// ============================================================

- (void)loadEmotesForChannelName:(NSString *)channelName {
    if (!channelName || channelName.length == 0) return;

    [self log:@"Channel rejoint: %@, recherche ID Twitch...", channelName];

    // Mémoriser le channel courant
    self.currentChannelName = channelName;

    // Si on a déjà l'ID pour ce channel, charger directement
    // (le currentChannelTwitchID est mis à jour par extractAndLoadEmotesFromGQLResponse)
    // On attend un peu que Twitch charge le channel et envoie l'ID via GQL
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

        if (self.currentChannelTwitchID) {
            [self loadEmotesForChannelTwitchID:self.currentChannelTwitchID];
        }
    });
}


// ============================================================
// MARK: - Chargement des emotes d'un channel par ID Twitch
// API: GET https://7tv.io/v3/users/twitch/{twitch_id}
// ============================================================

- (void)loadEmotesForChannelTwitchID:(NSString *)twitchUserID {
    if (!twitchUserID || twitchUserID.length == 0) return;

    // Éviter de recharger si déjà fait
    if ([self.loadedChannelIDs containsObject:twitchUserID]) {
        [self log:@"Emotes du channel %@ déjà en cache", twitchUserID];
        return;
    }

    [self log:@"Chargement des emotes du channel Twitch ID: %@", twitchUserID];

    // Charger le cache disque immédiatement (avant la requête réseau)
    NSString *cacheKey = [NSString stringWithFormat:@"s7tv_cache_ch_%@", twitchUserID];
    NSDictionary *cachedChannel = [self loadEmotesFromCacheForKey:cacheKey];
    if (cachedChannel.count) {
        dispatch_barrier_async(self.emoteQueue, ^{
            self.channelEmotes = cachedChannel;
        });
        [self log:@"⚡️ %lu emotes channel depuis cache disque", (unsigned long)cachedChannel.count];
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/users/twitch/%@",
                        S7TV_API_BASE, twitchUserID];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    [[session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        if (error || !data) {
            [self log:@"❌ Erreur chargement emotes channel: %@", error.localizedDescription];
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                             options:0
                                                               error:nil];
        if (!json) return;

        // La réponse contient un objet "emote_set" avec les emotes du channel
        id rawEmoteSet = json[@"emote_set"];
        NSDictionary *emoteSet = [rawEmoteSet isKindOfClass:[NSDictionary class]] ? rawEmoteSet : nil;
        if (!emoteSet) {
            [self log:@"Pas d'emote_set pour ce channel (channel pas sur 7TV?)"];
            return;
        }

        NSDictionary *parsed = [self parseEmoteSetJSON:emoteSet];

        dispatch_barrier_async(self.emoteQueue, ^{
            self.channelEmotes = parsed;
            [self.loadedChannelIDs addObject:twitchUserID];
            [self log:@"✅ %lu emotes du channel chargées", (unsigned long)parsed.count];
            // Sauvegarder dans le cache disque pour le prochain lancement
            NSString *cacheKey = [NSString stringWithFormat:@"s7tv_cache_ch_%@", twitchUserID];
            [self saveEmotesToCache:parsed forKey:cacheKey];
        });

    }] resume];
}


// ============================================================
// MARK: - Parsing JSON d'un emote-set 7TV
// Retourne un dictionnaire: { "nom_emote" -> SevenTVEmote }
// ============================================================

- (NSDictionary<NSString *, SevenTVEmote *> *)parseEmoteSetJSON:(NSDictionary *)json {
    NSArray *emotesList = json[@"emotes"];
    if (![emotesList isKindOfClass:[NSArray class]]) return @{};

    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:emotesList.count];

    for (id item in emotesList) {
        // Chaque item a la forme:
        // { "id": "...", "name": "KEKW", "data": { "animated": true/false } }

        // Défense: l'API peut retourner NSNull à n'importe quel niveau
        if (![item isKindOfClass:[NSDictionary class]]) continue;

        NSString *name   = item[@"name"];
        NSString *itemID = item[@"id"];

        // NSNull guard: name et itemID peuvent être NSNull (JSON null)
        if (![name isKindOfClass:[NSString class]])   name   = nil;
        if (![itemID isKindOfClass:[NSString class]]) itemID = nil;

        // Certains items ont les données dans une clé "data"
        // "data" peut être NSNull si l'API retourne null pour ce champ
        id rawData = item[@"data"];
        NSDictionary *data = [rawData isKindOfClass:[NSDictionary class]] ? rawData : nil;

        id rawEmoteID = data[@"id"];
        NSString *emoteID = [rawEmoteID isKindOfClass:[NSString class]] ? rawEmoteID : itemID;

        id rawAnimated = data[@"animated"];
        BOOL animated  = [rawAnimated isKindOfClass:[NSNumber class]] && [rawAnimated boolValue];

        if (!name || !emoteID) continue;

        SevenTVEmote *emote = [[SevenTVEmote alloc] init];
        emote.emoteID       = emoteID;
        emote.emoteName     = name;
        emote.isAnimated    = animated;

        result[name] = emote;
    }

    return [result copy];
}


// ============================================================
// MARK: - Extraction du broadcaster ID depuis les réponses GQL Twitch
//
// Twitch envoie des requêtes GraphQL à gql.twitch.tv qui contiennent
// l'ID du broadcaster dans la réponse JSON. On parse ces réponses
// pour extraire cet ID et charger les emotes 7TV du channel.
// ============================================================

- (void)extractAndLoadEmotesFromGQLResponse:(NSData *)responseData {
    if (!responseData) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSError *error;

        // Les réponses GQL peuvent être un array ou un objet
        id json = [NSJSONSerialization JSONObjectWithData:responseData
                                                  options:0
                                                    error:&error];
        if (!json || error) return;

        // Normaliser en array pour traiter les deux cas
        NSArray *responses = [json isKindOfClass:[NSArray class]] ? json : @[json];

        for (NSDictionary *response in responses) {
            if (![response isKindOfClass:[NSDictionary class]]) continue;

            // Chercher de manière récursive un ID de broadcaster ET son login
            NSString *channelLogin = nil;
            NSString *broadcasterID = [self findBroadcasterIDInObject:response
                                                         channelLogin:&channelLogin];

            if (!broadcasterID) continue;

            // Mettre à jour le channel name dès qu'on le trouve (meme si ID identique)
            if (channelLogin.length > 0) {
                self.currentChannelName = channelLogin;
                [self log:@"📡 Channel name extrait GQL: %@", channelLogin];
            }

            // Si l'ID a change -> nouveau channel -> reset + reload
            if (![broadcasterID isEqualToString:self.currentChannelTwitchID]) {
                [self log:@"📡 Nouveau broadcaster ID via GQL: %@ (ancien: %@)",
                 broadcasterID, self.currentChannelTwitchID ?: @"aucun"];

                // Reset des emotes du channel precedent (fix bug cache)
                NSString *oldID = self.currentChannelTwitchID;
                dispatch_barrier_async(self.emoteQueue, ^{
                    self.channelEmotes = @{};
                    if (oldID) [self.loadedChannelIDs removeObject:oldID];
                });

                self.currentChannelTwitchID = broadcasterID;
                [self loadEmotesForChannelTwitchID:broadcasterID];
                break;
            }
        }
    });
}

// Cherche récursivement un broadcaster ID dans un objet JSON.
// Si outLogin != NULL, remplit aussi le login/nom du channel quand disponible.
- (NSString *)findBroadcasterIDInObject:(id)obj
                           channelLogin:(NSString **)outLogin {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;

        // Clés courantes dans les réponses GQL de Twitch pour identifier un canal
        NSArray *channelKeys = @[@"channel", @"broadcaster", @"user", @"streamer", @"owner"];
        for (NSString *key in channelKeys) {
            id value = dict[key];
            if ([value isKindOfClass:[NSDictionary class]]) {
                // Un ID Twitch est numérique et généralement > 4 chiffres
                NSString *foundID = value[@"id"];
                if ([self isTwitchUserID:foundID]) {
                    // Extraire aussi le login si disponible
                    if (outLogin) {
                        id rawLogin = value[@"login"] ?: value[@"name"];
                        NSString *login = [rawLogin isKindOfClass:[NSString class]] ? rawLogin : nil;
                        if (login.length > 0) {
                            *outLogin = login;
                        }
                    }
                    return foundID;
                }
            }
        }

        // Chercher "broadcastUser" ou patterns similaires en récursion
        for (NSString *key in dict) {
            if ([key.lowercaseString containsString:@"broadcast"] ||
                [key.lowercaseString containsString:@"channel"]) {
                NSString *result = [self findBroadcasterIDInObject:dict[key]
                                                      channelLogin:outLogin];
                if (result) return result;
            }
        }
    }

    if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            NSString *result = [self findBroadcasterIDInObject:item
                                                  channelLogin:outLogin];
            if (result) return result;
        }
    }

    return nil;
}

// Vérifie si une chaîne ressemble à un ID utilisateur Twitch (numérique, 6-15 chiffres)
- (BOOL)isTwitchUserID:(id)value {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *str = value;
    if (str.length < 4 || str.length > 15) return NO;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return ([str rangeOfCharacterFromSet:nonDigits].location == NSNotFound);
}


// ============================================================
// MARK: - Injection des emotes 7TV dans les messages IRC
//
// Format du tag @emotes dans IRC Twitch:
//   @emotes=emoteId:startPos-endPos,emoteId2:startPos2-endPos2
// Exemple avec Kappa (ID=25) au début "Kappa hello":
//   @emotes=25:0-4
//
// On utilise des faux IDs préfixés par "7tv_" pour nos emotes.
// Notre NSURLProtocol (SevenTVURLProtocol) intercepte ensuite la
// requête d'image pour ces faux IDs et redirige vers le CDN 7TV.
// ============================================================

- (NSString *)injectSevenTVEmotesIntoIRCMessage:(NSString *)rawMessage {
    // Vérifications préliminaires
    if (!self.isEnabled || rawMessage.length == 0) return rawMessage;

    // On ne traite que les messages PRIVMSG (messages de chat)
    if (![rawMessage containsString:@"PRIVMSG"]) return rawMessage;

    // --- Extraire le texte du message ---
    // Format IRC: "@tags :user!user@user.tmi.twitch.tv PRIVMSG #channel :message texte"
    NSRange privmsgRange = [rawMessage rangeOfString:@"PRIVMSG #"];
    if (privmsgRange.location == NSNotFound) return rawMessage;

    NSString *afterPrivmsg = [rawMessage substringFromIndex:privmsgRange.location + privmsgRange.length];
    NSRange colonRange = [afterPrivmsg rangeOfString:@" :"];
    if (colonRange.location == NSNotFound) return rawMessage;

    NSString *messageText = [afterPrivmsg substringFromIndex:colonRange.location + 2];

    // Fix 1 — Les frames IRC se terminent par \r\n.
    // Sans ce trim, le dernier mot est "KEKW\r\n" au lieu de "KEKW"
    // → le dictionnaire d'emotes ne trouve jamais de correspondance.
    messageText = [messageText stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (messageText.length == 0) return rawMessage;

    // Diagnostic — voir exactement le texte parsé (à retirer une fois confirmé)
    [self log:@"🔎 Texte parsé: \"%@\"", messageText];

    // --- Obtenir la liste combinée de toutes les emotes connues ---
    __block NSDictionary *global;
    __block NSDictionary *channel;
    dispatch_sync(self.emoteQueue, ^{
        global  = self.globalEmotes  ?: @{};
        channel = self.channelEmotes ?: @{};
    });

    // --- Trouver les emotes dans le message ---
    NSMutableArray *emoteTags = [NSMutableArray array];
    NSArray *words = [messageText componentsSeparatedByString:@" "];
    NSUInteger currentPos = 0;

    for (NSString *word in words) {
        if (word.length == 0) {
            currentPos += 1; // espace
            continue;
        }

        // Chercher ce mot dans nos emotes (channel en priorité sur global)
        SevenTVEmote *emote = channel[word] ?: global[word];

        if (emote) {
            // Ignorer les emotes animées si l'option est désactivée
            if (emote.isAnimated && !self.showAnimated) {
                currentPos += word.length + 1;
                continue;
            }

            // Calculer les positions dans la chaîne UTF-8
            NSUInteger startPos = currentPos;
            NSUInteger endPos   = currentPos + word.length - 1;

            // Créer le tag: "7tv_EMOTEID:START-END"
            NSString *tag = [NSString stringWithFormat:@"%@%@:%lu-%lu",
                             S7TV_EMOTE_ID_PREFIX, emote.emoteID,
                             (unsigned long)startPos,
                             (unsigned long)endPos];
            [emoteTags addObject:tag];

            [self log:@"🎭 Emote trouvée: %@ (ID: %@)", word, emote.emoteID];
        }

        currentPos += word.length + 1; // +1 pour l'espace
    }

    // Si aucune emote 7TV trouvée, retourner le message original
    if (emoteTags.count == 0) return rawMessage;

    // --- Modifier le tag @emotes dans l'en-tête IRC ---
    // Chercher le tag "emotes=" existant pour y ajouter nos emotes
    NSString *newEmotesStr = [emoteTags componentsJoinedByString:@","];

    NSRange emoteTagRange = [rawMessage rangeOfString:@"emotes="];
    if (emoteTagRange.location != NSNotFound) {
        // Il y a déjà des emotes Twitch - on ajoute les nôtres à la suite
        NSUInteger insertPos = emoteTagRange.location + emoteTagRange.length;

        // Trouver la fin du tag emotes existant (prochain ";" ou fin de tags)
        NSString *afterEmotes = [rawMessage substringFromIndex:insertPos];
        NSRange semicolonRange = [afterEmotes rangeOfString:@";"];

        NSString *prefix  = [rawMessage substringToIndex:insertPos];
        NSString *suffix;

        if (semicolonRange.location != NSNotFound) {
            // Il y a d'autres tags après
            NSString *existingEmotes = [afterEmotes substringToIndex:semicolonRange.location];
            suffix = [afterEmotes substringFromIndex:semicolonRange.location];

            NSString *combined = existingEmotes.length > 0
                ? [NSString stringWithFormat:@"%@,%@", existingEmotes, newEmotesStr]
                : newEmotesStr;

            return [NSString stringWithFormat:@"%@%@%@", prefix, combined, suffix];
        } else {
            // emotes est le dernier tag
            return [NSString stringWithFormat:@"%@%@", prefix, newEmotesStr];
        }
    } else {
        // Pas de tag emotes - on l'ajoute au début des tags
        // Format: "@emotes=xxx;tags_existants ..."
        if ([rawMessage hasPrefix:@"@"]) {
            NSString *withoutAt = [rawMessage substringFromIndex:1];
            return [NSString stringWithFormat:@"@emotes=%@;%@", newEmotesStr, withoutAt];
        } else {
            return [NSString stringWithFormat:@"@emotes=%@ %@", newEmotesStr, rawMessage];
        }
    }
}


// ============================================================
// MARK: - Accès aux emotes
// ============================================================

- (SevenTVEmote *)emoteForName:(NSString *)name {
    __block SevenTVEmote *emote = nil;
    dispatch_sync(self.emoteQueue, ^{
        emote = self.channelEmotes[name] ?: self.globalEmotes[name];
    });
    return emote;
}

- (NSURL *)cdnURLForEmote:(SevenTVEmote *)emote {
    if (!emote) return nil;
    NSString *urlStr = [NSString stringWithFormat:@"%@/%@/4x.webp",
                        S7TV_CDN_BASE, emote.emoteID];
    return [NSURL URLWithString:urlStr];
}


// ============================================================
// MARK: - Bouton de paramètres flottant
//
// Un petit bouton violet "7TV" apparaît en bas à droite de l'écran.
// Il est draggable (glissable) et ouvre les paramètres au tap.
// ============================================================

- (void)addSettingsButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;

        // Trouver la fenêtre principale
        if (@available(iOS 15.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    for (UIWindow *w in windowScene.windows) {
                        if (w.isKeyWindow) { window = w; break; }
                    }
                }
            }
        }

        if (!window) {
            window = [UIApplication sharedApplication].windows.firstObject;
        }

        if (!window) return;

        // Créer le bouton
        CGFloat size = 44.0;
        CGFloat margin = 16.0;
        CGFloat x = window.bounds.size.width - size - margin;
        CGFloat y = window.bounds.size.height - size - margin - 80.0; // Au-dessus de la tabbar

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(x, y, size, size);
        btn.backgroundColor = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:0.88];
        btn.layer.cornerRadius = size / 2.0;
        btn.layer.shadowColor  = [UIColor blackColor].CGColor;
        btn.layer.shadowOffset = CGSizeMake(0, 2);
        btn.layer.shadowRadius = 4;
        btn.layer.shadowOpacity = 0.4;

        // Label "7TV"
        [btn setTitle:@"7TV" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

        // Actions
        [btn addTarget:self
                action:@selector(settingsButtonTapped:)
      forControlEvents:UIControlEventTouchUpInside];

        // Drag pour déplacer le bouton
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleSettingsButtonDrag:)];
        [btn addGestureRecognizer:pan];

        [window addSubview:btn];
        self.settingsButton = btn;
    });
}

- (void)settingsButtonTapped:(UIButton *)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        SevenTVSettingsController *settingsVC = [[SevenTVSettingsController alloc] init];
        UINavigationController *navVC = [[UINavigationController alloc]
                                         initWithRootViewController:settingsVC];

        // Présenter par-dessus l'UI actuelle
        UIViewController *topVC = [self topViewController];
        if (topVC) {
            [topVC presentViewController:navVC animated:YES completion:nil];
        }
    });
}

- (void)handleSettingsButtonDrag:(UIPanGestureRecognizer *)gesture {
    UIView *btn  = gesture.view;
    UIView *parent = btn.superview;
    if (!parent) return;

    CGPoint translation = [gesture translationInView:parent];
    CGPoint newCenter   = CGPointMake(btn.center.x + translation.x,
                                      btn.center.y + translation.y);

    // Garder dans les limites de l'écran
    CGFloat halfW = btn.bounds.size.width  / 2.0;
    CGFloat halfH = btn.bounds.size.height / 2.0;
    newCenter.x = MAX(halfW, MIN(parent.bounds.size.width  - halfW, newCenter.x));
    newCenter.y = MAX(halfH, MIN(parent.bounds.size.height - halfH, newCenter.y));

    btn.center = newCenter;
    [gesture setTranslation:CGPointZero inView:parent];
}

- (UIViewController *)topViewController {
    UIViewController *vc = nil;
    UIWindow *window = nil;

    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) { window = w; break; }
                }
            }
        }
    }
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;

    vc = window.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}


// ============================================================
// MARK: - Logging (buffer in-app + console optionnelle)
//
// IMPORTANT: log: enregistre TOUJOURS dans le buffer in-app,
// même si debugLogging == NO. Ça permet de diagnostiquer les
// problèmes sans avoir un Mac branché.
// NSLog (visible dans Console.app) est lui conditionné à debugLogging.
// ============================================================

- (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Horodatage compact: HH:mm:ss.SSS
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];

    NSString *line = [NSString stringWithFormat:@"[%@] %@", timestamp, msg];

    // ── Ajout au buffer (thread-safe) ──
    [self.logLock lock];
    [self.logBuffer addObject:line];
    // Écrêtage: on supprime les lignes les plus anciennes si besoin
    if (self.logBuffer.count > S7TV_LOG_BUFFER_MAX) {
        NSUInteger excess = self.logBuffer.count - S7TV_LOG_BUFFER_MAX;
        [self.logBuffer removeObjectsInRange:NSMakeRange(0, excess)];
    }
    [self.logLock unlock];

    // ── NSLog console (seulement si debugLogging activé) ──
    if (self.debugLogging) {
        NSLog(@"[TwitchSevenTV] %@", msg);
    }

    // ── Notification (toujours, pour que SevenTVLogsController se rafraîchisse) ──
    // Postée sur le main thread pour que les observers UI puissent agir directement.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVLogsDidUpdateNotification
                          object:self
                        userInfo:@{@"line": line}];
    });
}

// Retourne une copie snapshot du buffer (thread-safe)
- (NSArray<NSString *> *)allLogs {
    [self.logLock lock];
    NSArray *copy = [self.logBuffer copy];
    [self.logLock unlock];
    return copy;
}

// Vide le buffer
- (void)clearLogs {
    [self.logLock lock];
    [self.logBuffer removeAllObjects];
    [self.logLock unlock];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVLogsDidUpdateNotification
                          object:self
                        userInfo:@{@"cleared": @YES}];
    });
}

@end
