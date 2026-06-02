/*
 * SevenTVManager.m
 * Implémentation du gestionnaire 7TV.
 *
 * CORRECTIFS v1.4:
 *   Fix C — Injection IRC: traiter chaque ligne IRC séparément.
 *            Twitch envoie parfois plusieurs messages dans un seul paquet
 *            WebSocket (séparés par \r\n). L'ancien code cherchait "emotes="
 *            dans tout le paquet → trouvait celui d'une autre ligne → injectait
 *            au mauvais endroit. Résultat: l'emote était "injectée" mais dans
 *            un tag inutilisable, Twitch ignorait l'image.
 *
 *   Fix D — Log de diagnostic étendu: le tag final complet (pas tronqué à 120)
 *            est loggué quand une emote est injectée, pour faciliter le debug.
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
// File de dispatch pour la thread-safety des données d'emotes (readwrite en privé)
@property (nonatomic, strong, readwrite) dispatch_queue_t emoteQueue;
// Bouton flottant des paramètres
@property (nonatomic, weak) UIButton *settingsButton;

// ── Buffer de logs in-app ──────────────────────────────────
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
        _isEnabled    = YES;
        _showAnimated = YES;
        _debugLogging = (S7TV_DEBUG == 1);

        _globalEmotes  = @{};
        _channelEmotes = @{};
        _loadedChannelIDs = [NSMutableSet set];
        _emoteQueue = dispatch_queue_create("tv.s7tv.emote-queue",
                                            DISPATCH_QUEUE_CONCURRENT);

        _logBuffer = [NSMutableArray arrayWithCapacity:256];
        _logLock   = [[NSLock alloc] init];

        [self loadPreferences];
    }
    return self;
}


// ============================================================
// MARK: - Cache disque (NSUserDefaults)
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

    NSDictionary *cachedGlobal = [self loadEmotesFromCacheForKey:kCacheGlobal];
    if (cachedGlobal.count) {
        dispatch_barrier_async(self.emoteQueue, ^{
            self.globalEmotes = cachedGlobal;
        });
        [self log:@"⚡️ %lu emotes globales depuis cache disque", (unsigned long)cachedGlobal.count];
    }

    [self loadGlobalEmotes];
}


// ============================================================
// MARK: - Préférences utilisateur
// ============================================================

- (void)loadPreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if ([prefs objectForKey:@"s7tv_enabled"] != nil)
        _isEnabled = [prefs boolForKey:@"s7tv_enabled"];
    if ([prefs objectForKey:@"s7tv_animated"] != nil)
        _showAnimated = [prefs boolForKey:@"s7tv_animated"];
    if ([prefs objectForKey:@"s7tv_debug"] != nil)
        _debugLogging = [prefs boolForKey:@"s7tv_debug"];
}

- (void)savePreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setBool:self.isEnabled    forKey:@"s7tv_enabled"];
    [prefs setBool:self.showAnimated forKey:@"s7tv_animated"];
    [prefs setBool:self.debugLogging forKey:@"s7tv_debug"];
    [prefs synchronize];
}

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

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) {
            [self log:@"❌ JSON invalide pour les emotes globales"];
            return;
        }

        NSDictionary *parsed = [self parseEmoteSetJSON:json];
        dispatch_barrier_async(self.emoteQueue, ^{
            self.globalEmotes = parsed;
            [self log:@"✅ %lu emotes globales 7TV chargées", (unsigned long)parsed.count];
            [self saveEmotesToCache:parsed forKey:kCacheGlobal];
        });

    }] resume];
}


// ============================================================
// MARK: - Chargement des emotes d'un channel par nom
// ============================================================

- (void)loadEmotesForChannelName:(NSString *)channelName {
    if (!channelName || channelName.length == 0) return;

    [self log:@"Channel rejoint: %@, recherche ID Twitch...", channelName];
    self.currentChannelName = channelName;

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

    if ([self.loadedChannelIDs containsObject:twitchUserID]) {
        [self log:@"Emotes du channel %@ déjà en cache", twitchUserID];
        return;
    }

    [self log:@"Chargement des emotes du channel Twitch ID: %@", twitchUserID];

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

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) return;

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
            NSString *ck = [NSString stringWithFormat:@"s7tv_cache_ch_%@", twitchUserID];
            [self saveEmotesToCache:parsed forKey:ck];
        });

    }] resume];
}


// ============================================================
// MARK: - Parsing JSON d'un emote-set 7TV
// ============================================================

- (NSDictionary<NSString *, SevenTVEmote *> *)parseEmoteSetJSON:(NSDictionary *)json {
    NSArray *emotesList = json[@"emotes"];
    if (![emotesList isKindOfClass:[NSArray class]]) return @{};

    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:emotesList.count];

    for (id item in emotesList) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;

        NSString *name   = item[@"name"];
        NSString *itemID = item[@"id"];

        if (![name isKindOfClass:[NSString class]])   name   = nil;
        if (![itemID isKindOfClass:[NSString class]]) itemID = nil;

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
// ============================================================

- (void)extractAndLoadEmotesFromGQLResponse:(NSData *)responseData {
    if (!responseData) return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSError *error;
        id json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&error];
        if (!json || error) return;

        NSArray *responses = [json isKindOfClass:[NSArray class]] ? json : @[json];

        for (NSDictionary *response in responses) {
            if (![response isKindOfClass:[NSDictionary class]]) continue;

            NSString *channelLogin = nil;
            NSString *broadcasterID = [self findBroadcasterIDInObject:response
                                                         channelLogin:&channelLogin];

            if (!broadcasterID) continue;

            if (channelLogin.length > 0) {
                self.currentChannelName = channelLogin;
                [self log:@"📡 Channel name extrait GQL: %@", channelLogin];
            }

            if (![broadcasterID isEqualToString:self.currentChannelTwitchID]) {
                [self log:@"📡 Nouveau broadcaster ID via GQL: %@ (ancien: %@)",
                 broadcasterID, self.currentChannelTwitchID ?: @"aucun"];

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

- (NSString *)findBroadcasterIDInObject:(id)obj
                           channelLogin:(NSString **)outLogin {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;

        NSArray *channelKeys = @[@"channel", @"broadcaster", @"user", @"streamer", @"owner"];
        for (NSString *key in channelKeys) {
            id value = dict[key];
            if ([value isKindOfClass:[NSDictionary class]]) {
                NSString *foundID = value[@"id"];
                if ([self isTwitchUserID:foundID]) {
                    if (outLogin) {
                        id rawLogin = value[@"login"] ?: value[@"name"];
                        NSString *login = [rawLogin isKindOfClass:[NSString class]] ? rawLogin : nil;
                        if (login.length > 0) *outLogin = login;
                    }
                    return foundID;
                }
            }
        }

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
            NSString *result = [self findBroadcasterIDInObject:item channelLogin:outLogin];
            if (result) return result;
        }
    }

    return nil;
}

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
// FIX C (v1.4): Un paquet WebSocket peut contenir plusieurs lignes IRC
// séparées par \r\n. On traite chaque ligne indépendamment pour éviter
// que la recherche de "emotes=" d'une ligne n'interfère avec une autre.
//
// Exemple de paquet multi-lignes:
//   @badge-info=...;emotes=25:0-4 :user1 PRIVMSG #ch :Kappa\r\n
//   @badge-info=...;badges=...    :user2 PRIVMSG #ch :ptn
//
// Avant: "emotes=" était trouvé dans la ligne 1, mais PRIVMSG dans la ligne 2
//        → injection au mauvais endroit → tag incohérent → Twitch ignorait l'image.
// Après: chaque ligne est traitée séparément → injection toujours correcte.
// ============================================================

- (NSString *)injectSevenTVEmotesIntoIRCMessage:(NSString *)rawMessage {
    if (!self.isEnabled || rawMessage.length == 0) return rawMessage;

    // Séparer les lignes IRC (paquet multi-messages)
    NSArray<NSString *> *lines = [rawMessage componentsSeparatedByString:@"\r\n"];

    // Optimisation: si une seule ligne, pas besoin de rejoindre
    if (lines.count == 1) {
        return [self injectIntoSingleIRCLine:rawMessage];
    }

    BOOL modified = NO;
    NSMutableArray<NSString *> *processedLines = [NSMutableArray arrayWithCapacity:lines.count];

    for (NSString *line in lines) {
        if (line.length == 0) {
            // Conserver les lignes vides (terminateur \r\n final)
            [processedLines addObject:line];
            continue;
        }
        NSString *processed = [self injectIntoSingleIRCLine:line];
        if (!modified && ![processed isEqualToString:line]) {
            modified = YES;
        }
        [processedLines addObject:processed];
    }

    return modified ? [processedLines componentsJoinedByString:@"\r\n"] : rawMessage;
}


// ============================================================
// MARK: - Injection sur une seule ligne IRC (logique principale)
//
// Format IRC Twitch:
//   @tags :user!user@tmi.twitch.tv PRIVMSG #channel :texte du message
//
// On cherche les mots du texte dans notre dictionnaire d'emotes,
// puis on injecte les positions dans le tag "emotes=" des @tags.
// ============================================================

- (NSString *)injectIntoSingleIRCLine:(NSString *)line {
    // On ne traite que les PRIVMSG
    if (![line containsString:@"PRIVMSG"]) return line;

    // ── Extraire le texte du message ──────────────────────────
    NSRange privmsgRange = [line rangeOfString:@"PRIVMSG #"];
    if (privmsgRange.location == NSNotFound) return line;

    NSString *afterPrivmsg = [line substringFromIndex:privmsgRange.location + privmsgRange.length];
    NSRange colonRange = [afterPrivmsg rangeOfString:@" :"];
    if (colonRange.location == NSNotFound) return line;

    NSString *messageText = [afterPrivmsg substringFromIndex:colonRange.location + 2];

    // Supprimer \r\n éventuels en fin de ligne
    messageText = [messageText stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (messageText.length == 0) return line;

    // ── Lire les emotes connues (thread-safe) ─────────────────
    __block NSDictionary *global;
    __block NSDictionary *channel;
    dispatch_sync(self.emoteQueue, ^{
        global  = self.globalEmotes  ?: @{};
        channel = self.channelEmotes ?: @{};
    });

    // ── Trouver les emotes 7TV dans le message ─────────────────
    NSMutableArray<NSString *> *emoteTags = [NSMutableArray array];
    NSArray<NSString *> *words = [messageText componentsSeparatedByString:@" "];
    NSUInteger currentPos = 0;

    for (NSString *word in words) {
        if (word.length == 0) {
            currentPos += 1;
            continue;
        }

        SevenTVEmote *emote = channel[word] ?: global[word];

        if (emote) {
            if (emote.isAnimated && !self.showAnimated) {
                currentPos += word.length + 1;
                continue;
            }

            NSUInteger startPos = currentPos;
            NSUInteger endPos   = currentPos + word.length - 1;

            NSString *tag = [NSString stringWithFormat:@"%@%@:%lu-%lu",
                             S7TV_EMOTE_ID_PREFIX, emote.emoteID,
                             (unsigned long)startPos,
                             (unsigned long)endPos];
            [emoteTags addObject:tag];

            [self log:@"🎭 Emote trouvée: %@ (ID: %@) pos:%lu-%lu",
             word, emote.emoteID, (unsigned long)startPos, (unsigned long)endPos];
        }

        currentPos += word.length + 1;
    }

    if (emoteTags.count == 0) return line;

    [self log:@"💉 Injection de %lu emote(s): %@",
     (unsigned long)emoteTags.count,
     [emoteTags componentsJoinedByString:@" | "]];

    // ── Injecter dans le tag emotes= de CETTE ligne ───────────
    NSString *newEmotesStr = [emoteTags componentsJoinedByString:@","];
    NSString *result = [self buildIRCLineWithEmotes:newEmotesStr inLine:line];

    // Log diagnostic: les 150 premiers caractères du résultat final
    [self log:@"🏷 tag final -> %@",
     [result substringToIndex:MIN((NSUInteger)150, result.length)]];

    return result;
}


// ============================================================
// MARK: - Construction du tag emotes= dans une ligne IRC
//
// Deux cas:
//   A) La ligne contient déjà "emotes=" → on fusionne (append)
//   B) La ligne n'a pas de "emotes="   → on insère au début des @tags
// ============================================================

- (NSString *)buildIRCLineWithEmotes:(NSString *)newEmotesStr inLine:(NSString *)line {

    NSRange emoteTagRange = [line rangeOfString:@"emotes="];

    if (emoteTagRange.location != NSNotFound) {
        // ── Cas A: tag emotes= existant ───────────────────────
        // On cherche la fin de la valeur: premier ';' ou ' ' après "emotes="
        NSUInteger insertPos = emoteTagRange.location + emoteTagRange.length;
        NSString *afterEmotes = [line substringFromIndex:insertPos];

        NSRange sc = [afterEmotes rangeOfString:@";"];
        NSRange sp = [afterEmotes rangeOfString:@" "];
        NSUInteger limit = afterEmotes.length;
        if (sc.location != NSNotFound) limit = sc.location;
        if (sp.location != NSNotFound && sp.location < limit) limit = sp.location;

        NSString *prefix         = [line substringToIndex:insertPos];
        NSString *existingEmotes = [afterEmotes substringToIndex:limit];
        NSString *suffix         = [afterEmotes substringFromIndex:limit];

        // Si la valeur existante est vide (emotes=;) on ne met pas de virgule
        NSString *combined = existingEmotes.length > 0
            ? [NSString stringWithFormat:@"%@,%@", existingEmotes, newEmotesStr]
            : newEmotesStr;

        return [NSString stringWithFormat:@"%@%@%@", prefix, combined, suffix];

    } else {
        // ── Cas B: pas de tag emotes= → on l'insère en tête des @tags ──
        if ([line hasPrefix:@"@"]) {
            // "@badge-info=..." → "@emotes=XXX;badge-info=..."
            NSString *withoutAt = [line substringFromIndex:1];
            return [NSString stringWithFormat:@"@emotes=%@;%@", newEmotesStr, withoutAt];
        } else {
            // Ligne sans @ (inhabituel mais géré)
            return [NSString stringWithFormat:@"@emotes=%@ %@", newEmotesStr, line];
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
// ============================================================

- (void)addSettingsButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;

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

        if (!window) window = [UIApplication sharedApplication].windows.firstObject;
        if (!window) return;

        CGFloat size = 44.0;
        CGFloat margin = 16.0;
        CGFloat x = window.bounds.size.width - size - margin;
        CGFloat y = window.bounds.size.height - size - margin - 80.0;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(x, y, size, size);
        btn.backgroundColor = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:0.88];
        btn.layer.cornerRadius = size / 2.0;
        btn.layer.shadowColor  = [UIColor blackColor].CGColor;
        btn.layer.shadowOffset = CGSizeMake(0, 2);
        btn.layer.shadowRadius = 4;
        btn.layer.shadowOpacity = 0.4;

        [btn setTitle:@"7TV" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

        [btn addTarget:self
                action:@selector(settingsButtonTapped:)
      forControlEvents:UIControlEventTouchUpInside];

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
        UIViewController *topVC = [self topViewController];
        if (topVC) {
            [topVC presentViewController:navVC animated:YES completion:nil];
        }
    });
}

- (void)handleSettingsButtonDrag:(UIPanGestureRecognizer *)gesture {
    UIView *btn    = gesture.view;
    UIView *parent = btn.superview;
    if (!parent) return;

    CGPoint translation = [gesture translationInView:parent];
    CGPoint newCenter   = CGPointMake(btn.center.x + translation.x,
                                      btn.center.y + translation.y);

    CGFloat halfW = btn.bounds.size.width  / 2.0;
    CGFloat halfH = btn.bounds.size.height / 2.0;
    newCenter.x = MAX(halfW, MIN(parent.bounds.size.width  - halfW, newCenter.x));
    newCenter.y = MAX(halfH, MIN(parent.bounds.size.height - halfH, newCenter.y));

    btn.center = newCenter;
    [gesture setTranslation:CGPointZero inView:parent];
}

- (UIViewController *)topViewController {
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

    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}


// ============================================================
// MARK: - Logging (buffer in-app + console optionnelle)
// ============================================================

- (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *timestamp = [fmt stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[%@] %@", timestamp, msg];

    [self.logLock lock];
    [self.logBuffer addObject:line];
    if (self.logBuffer.count > S7TV_LOG_BUFFER_MAX) {
        NSUInteger excess = self.logBuffer.count - S7TV_LOG_BUFFER_MAX;
        [self.logBuffer removeObjectsInRange:NSMakeRange(0, excess)];
    }
    [self.logLock unlock];

    if (self.debugLogging) {
        NSLog(@"[TwitchSevenTV] %@", msg);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVLogsDidUpdateNotification
                          object:self
                        userInfo:@{@"line": line}];
    });
}

- (NSArray<NSString *> *)allLogs {
    [self.logLock lock];
    NSArray *copy = [self.logBuffer copy];
    [self.logLock unlock];
    return copy;
}

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
