/*
 * SevenTVManager.m
 * Implémentation du gestionnaire 7TV.
 *
 * CORRECTIFS v1.4:
 *   Fix C — Injection IRC: traiter chaque ligne IRC séparément (paquets multi-messages).
 *   Fix D — Logs de diagnostic étendus (tag final complet, positions).
 *
 * NOUVEAUTÉS v1.5 — Cache & Préchargement:
 *   Fix E — Cache fichier JSON (remplace NSUserDefaults).
 *            Les emotes sont stockées dans Library/Caches/s7tv/ sous forme de
 *            fichiers JSON individuels par channel. Plus fiable, plus rapide à
 *            lire (lecture synchrone sur file I/O queue), et iOS peut les purger
 *            automatiquement si le stockage est plein sans crasher l'app.
 *
 *   Fix F — Stratégie cache-first + refresh arrière-plan.
 *            Comportement:
 *              1. Au JOIN d'un channel → cache chargé IMMÉDIATEMENT (synchrone)
 *                 → les emotes sont disponibles avant même le 1er message du chat.
 *              2. Si le cache date de plus de S7TV_CACHE_TTL secondes (1h par défaut)
 *                 → refresh API lancé en arrière-plan, chat non bloqué.
 *              3. Si pas de cache du tout → API fetch immédiat.
 *            Résultat: 2e lancement sur un channel déjà visité = 0 délai.
 *
 *   Fix G — Protection anti-doublons affinée.
 *            `fetchingChannelIDs` remplace `loadedChannelIDs`.
 *            Il n'empêche plus les refreshs futurs — il évite seulement deux
 *            requêtes réseau simultanées vers le même channel (ex: ROOMSTATE
 *            reçu deux fois rapidement). Les refreshs périodiques sont gérés
 *            par l'horodatage du cache, pas par ce set.
 */

#import "SevenTVManager.h"
#import "SevenTVSettingsController.h"
#import <objc/runtime.h>

// ============================================================
// Constante de notification
// ============================================================
NSString *const S7TVLogsDidUpdateNotification = @"S7TVLogsDidUpdateNotification";

// ============================================================
// TTL du cache en secondes
//   Globales : 1h  (elles changent très rarement)
//   Channel  : 30 min (le streamer peut ajouter/retirer des emotes)
// ============================================================
static const NSTimeInterval kCacheTTLGlobal  = 3600.0;   // 1 heure
static const NSTimeInterval kCacheTTLChannel = 1800.0;   // 30 minutes


// ============================================================
// Implémentation de SevenTVEmote
// ============================================================
@implementation SevenTVEmote
@end


// ============================================================
// SevenTVManager (privé)
// ============================================================
@interface SevenTVManager ()

// IDs de channels dont un fetch réseau est EN COURS (anti-doublon concurrent)
// Ne bloque PAS les futurs refreshs — seulement les requêtes simultanées.
@property (nonatomic, strong) NSMutableSet<NSString *> *fetchingChannelIDs;

// File de dispatch pour la thread-safety des données d'emotes
@property (nonatomic, strong, readwrite) dispatch_queue_t emoteQueue;

// File série pour les I/O fichier (lecture/écriture cache JSON)
// Série = pas de concurrent file access, pas besoin de lock séparé.
@property (nonatomic, strong) dispatch_queue_t fileIOQueue;

// Bouton flottant des paramètres
@property (nonatomic, weak) UIButton *settingsButton;

// Buffer de logs in-app
@property (nonatomic, strong) NSMutableArray<NSString *> *logBuffer;
@property (nonatomic, strong) NSLock *logLock;

// Dossier racine du cache JSON (créé à la demande)
@property (nonatomic, strong) NSString *cacheDirectory;

@end


@implementation SevenTVManager

// ============================================================
// MARK: - Singleton
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

        _globalEmotes      = @{};
        _channelEmotes     = @{};
        _fetchingChannelIDs = [NSMutableSet set];

        _emoteQueue  = dispatch_queue_create("tv.s7tv.emote-queue",  DISPATCH_QUEUE_CONCURRENT);
        _fileIOQueue = dispatch_queue_create("tv.s7tv.file-io-queue", DISPATCH_QUEUE_SERIAL);

        _logBuffer = [NSMutableArray arrayWithCapacity:256];
        _logLock   = [[NSLock alloc] init];

        [self loadPreferences];
        [self ensureCacheDirectory];
    }
    return self;
}


// ============================================================
// MARK: - Cache JSON sur disque (Library/Caches/s7tv/)
//
// Format de chaque fichier:
//   {
//     "ts": 1718000000,          ← timestamp Unix de la dernière mise à jour
//     "emotes": {
//       "KEKW": { "id": "...", "a": true },
//       "Pog":  { "id": "...", "a": false },
//       ...
//     }
//   }
//
// Noms de fichiers:
//   global.json          ← emotes globales 7TV
//   ch_155601320.json    ← emotes du channel Twitch ID 155601320
// ============================================================

- (void)ensureCacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *caches = paths.firstObject;
    NSString *dir = [caches stringByAppendingPathComponent:@"s7tv"];

    NSError *err;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&err];
    if (err) {
        NSLog(@"[TwitchSevenTV] ⚠️ Impossible de créer le dossier cache: %@", err.localizedDescription);
    }
    self.cacheDirectory = dir;
}

// Chemin complet d'un fichier cache
- (NSString *)cacheFilePathForName:(NSString *)name {
    return [self.cacheDirectory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.json", name]];
}

// ── Lecture synchrone (sur fileIOQueue) ───────────────────────────────────────
// Retourne le dictionnaire d'emotes et via outAge l'âge du cache en secondes.
// outAge = -1 si le fichier n'existe pas.
// APPELER DEPUIS fileIOQueue UNIQUEMENT (ou via dispatch_sync(fileIOQueue, ...))

- (NSDictionary<NSString *, SevenTVEmote *> *)_readCacheFile:(NSString *)path
                                                          age:(NSTimeInterval *)outAge {
    if (outAge) *outAge = -1;

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;

    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) return nil;

    // Âge du cache
    NSNumber *ts = root[@"ts"];
    if ([ts isKindOfClass:[NSNumber class]] && outAge) {
        *outAge = [NSDate date].timeIntervalSince1970 - ts.doubleValue;
    }

    NSDictionary *emotesDict = root[@"emotes"];
    if (![emotesDict isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:emotesDict.count];
    for (NSString *name in emotesDict) {
        NSDictionary *d = emotesDict[name];
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *emoteID = d[@"id"];
        if (![emoteID isKindOfClass:[NSString class]] || !emoteID.length) continue;

        SevenTVEmote *e = [[SevenTVEmote alloc] init];
        e.emoteName  = name;
        e.emoteID    = emoteID;
        e.isAnimated = [d[@"a"] boolValue];
        result[name] = e;
    }

    return result.count ? [result copy] : nil;
}

// ── Écriture asynchrone (sur fileIOQueue) ────────────────────────────────────
// Appelé depuis n'importe quel thread — dispatché sur fileIOQueue en interne.

- (void)_writeCacheFile:(NSString *)path
              withEmotes:(NSDictionary<NSString *, SevenTVEmote *> *)emotes {
    if (!emotes.count || !path) return;

    // Sérialiser
    NSMutableDictionary *emotesDict = [NSMutableDictionary dictionaryWithCapacity:emotes.count];
    for (NSString *name in emotes) {
        SevenTVEmote *e = emotes[name];
        emotesDict[name] = @{ @"id": e.emoteID, @"a": @(e.isAnimated) };
    }

    NSDictionary *root = @{
        @"ts":     @([NSDate date].timeIntervalSince1970),
        @"emotes": [emotesDict copy]
    };

    NSError *err;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:&err];
    if (!data || err) {
        [self log:@"⚠️ Impossible de sérialiser le cache: %@", err.localizedDescription];
        return;
    }

    dispatch_async(self.fileIOQueue, ^{
        BOOL ok = [data writeToFile:path atomically:YES];
        if (!ok) {
            [self log:@"⚠️ Écriture cache échouée: %@", path.lastPathComponent];
        }
    });
}

// ── API publique: charger depuis le cache ────────────────────────────────────
// Retourne les emotes immédiatement (synchrone sur l'appelant via dispatch_sync).
// outAge = âge en secondes (-1 = pas de cache).

- (NSDictionary<NSString *, SevenTVEmote *> *)loadCacheForName:(NSString *)name
                                                            age:(NSTimeInterval *)outAge {
    NSString *path = [self cacheFilePathForName:name];
    __block NSDictionary *result = nil;
    __block NSTimeInterval age = -1;

    dispatch_sync(self.fileIOQueue, ^{
        result = [self _readCacheFile:path age:&age];
    });

    if (outAge) *outAge = age;
    return result;
}

// ── API publique: sauvegarder dans le cache (async) ──────────────────────────

- (void)saveCacheForName:(NSString *)name
              withEmotes:(NSDictionary<NSString *, SevenTVEmote *> *)emotes {
    NSString *path = [self cacheFilePathForName:name];
    [self _writeCacheFile:path withEmotes:emotes];
}


// ============================================================
// MARK: - Initialisation
// ============================================================

- (void)setup {
    [self log:@"SevenTVManager: setup démarré"];

    // 1. Charger les emotes globales depuis le cache fichier (instantané)
    NSTimeInterval globalAge = -1;
    NSDictionary *cachedGlobal = [self loadCacheForName:@"global" age:&globalAge];

    if (cachedGlobal.count) {
        dispatch_barrier_async(self.emoteQueue, ^{
            self.globalEmotes = cachedGlobal;
        });
        if (globalAge >= 0) {
            [self log:@"⚡️ %lu emotes globales depuis cache (âge: %.0fs)",
             (unsigned long)cachedGlobal.count, globalAge];
        }
    }

    // 2. Refresh API si cache absent ou périmé
    if (globalAge < 0 || globalAge > kCacheTTLGlobal) {
        if (globalAge > kCacheTTLGlobal) {
            [self log:@"🔄 Cache global périmé (%.0fs) → refresh", globalAge];
        }
        [self loadGlobalEmotes];
    } else {
        [self log:@"✅ Cache global frais, pas de refresh réseau"];
    }
}


// ============================================================
// MARK: - Préférences utilisateur (NSUserDefaults — petit, OK ici)
// ============================================================

- (void)loadPreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    if ([prefs objectForKey:@"s7tv_enabled"]  != nil) _isEnabled    = [prefs boolForKey:@"s7tv_enabled"];
    if ([prefs objectForKey:@"s7tv_animated"] != nil) _showAnimated = [prefs boolForKey:@"s7tv_animated"];
    if ([prefs objectForKey:@"s7tv_debug"]    != nil) _debugLogging = [prefs boolForKey:@"s7tv_debug"];
}

- (void)savePreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setBool:self.isEnabled    forKey:@"s7tv_enabled"];
    [prefs setBool:self.showAnimated forKey:@"s7tv_animated"];
    [prefs setBool:self.debugLogging forKey:@"s7tv_debug"];
    [prefs synchronize];
}

- (void)setIsEnabled:(BOOL)v    { _isEnabled    = v; [self savePreferences]; }
- (void)setShowAnimated:(BOOL)v { _showAnimated  = v; [self savePreferences]; }
- (void)setDebugLogging:(BOOL)v { _debugLogging  = v; [self savePreferences]; }


// ============================================================
// MARK: - Chargement des emotes globales 7TV
// API: GET https://7tv.io/v3/emote-sets/global
// ============================================================

- (void)loadGlobalEmotes {
    [self log:@"🌍 Chargement emotes globales depuis API..."];

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/emote-sets/global", S7TV_API_BASE]];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        if (error || !data) {
            [self log:@"❌ Erreur emotes globales: %@", error.localizedDescription];
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) { [self log:@"❌ JSON invalide (globales)"]; return; }

        NSDictionary *parsed = [self parseEmoteSetJSON:json];
        if (!parsed.count) { [self log:@"⚠️ Aucune emote globale parsée"]; return; }

        dispatch_barrier_async(self.emoteQueue, ^{
            self.globalEmotes = parsed;
            [self log:@"✅ %lu emotes globales chargées depuis API", (unsigned long)parsed.count];
        });

        // Sauvegarder en cache (async, non bloquant)
        [self saveCacheForName:@"global" withEmotes:parsed];

    }] resume];
}


// ============================================================
// MARK: - Chargement des emotes d'un channel par nom
// ============================================================

- (void)loadEmotesForChannelName:(NSString *)channelName {
    if (!channelName.length) return;
    [self log:@"Channel rejoint: %@, recherche ID Twitch...", channelName];
    self.currentChannelName = channelName;

    // Attendre le ROOMSTATE (qui arrive ~100ms après le JOIN)
    // pour avoir le twitchID. Timeout de sécurité à 5s.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self.currentChannelTwitchID) {
            [self loadEmotesForChannelTwitchID:self.currentChannelTwitchID];
        }
    });
}


// ============================================================
// MARK: - Chargement des emotes d'un channel par ID Twitch
//
// Stratégie cache-first (Fix F):
//   1. Lire le cache fichier IMMÉDIATEMENT (synchrone sur fileIOQueue)
//      → les emotes sont dispo AVANT le 1er message du chat
//   2. Si cache frais (< 30 min) → on s'arrête là, pas de réseau
//   3. Si cache absent ou périmé → requête API en arrière-plan
//      → mise à jour transparente pendant que le chat tourne
// ============================================================

- (void)loadEmotesForChannelTwitchID:(NSString *)twitchUserID {
    if (!twitchUserID.length) return;

    // Anti-doublon concurrent: si une requête réseau est déjà en cours → ignorer
    @synchronized(self.fetchingChannelIDs) {
        if ([self.fetchingChannelIDs containsObject:twitchUserID]) {
            [self log:@"⏳ Fetch déjà en cours pour channel %@, ignoré", twitchUserID];
            return;
        }
    }

    NSString *cacheName = [NSString stringWithFormat:@"ch_%@", twitchUserID];

    // ── Étape 1: lire le cache immédiatement ──────────────────
    NSTimeInterval cacheAge = -1;
    NSDictionary *cached = [self loadCacheForName:cacheName age:&cacheAge];

    if (cached.count) {
        dispatch_barrier_async(self.emoteQueue, ^{
            self.channelEmotes = cached;
        });
        [self log:@"⚡️ %lu emotes channel depuis cache (âge: %.0fs)",
         (unsigned long)cached.count, cacheAge];
    }

    // ── Étape 2: décider si un refresh réseau est nécessaire ──
    BOOL cacheIsFresh = (cached.count > 0 && cacheAge >= 0 && cacheAge < kCacheTTLChannel);

    if (cacheIsFresh) {
        [self log:@"✅ Cache channel frais (%.0fs < %.0fs), pas de refresh",
         cacheAge, kCacheTTLChannel];
        return;
    }

    // ── Étape 3: requête API en arrière-plan ──────────────────
    if (cacheAge > 0) {
        [self log:@"🔄 Cache channel périmé (%.0fs) → refresh API", cacheAge];
    } else {
        [self log:@"🌐 Pas de cache pour channel %@ → fetch API", twitchUserID];
    }

    @synchronized(self.fetchingChannelIDs) {
        [self.fetchingChannelIDs addObject:twitchUserID];
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/users/twitch/%@", S7TV_API_BASE, twitchUserID];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        // Retirer de fetchingChannelIDs dans tous les cas
        @synchronized(self.fetchingChannelIDs) {
            [self.fetchingChannelIDs removeObject:twitchUserID];
        }

        if (error || !data) {
            [self log:@"❌ Erreur emotes channel %@: %@", twitchUserID, error.localizedDescription];
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!json) return;

        id rawEmoteSet = json[@"emote_set"];
        NSDictionary *emoteSet = [rawEmoteSet isKindOfClass:[NSDictionary class]] ? rawEmoteSet : nil;
        if (!emoteSet) {
            [self log:@"Pas d'emote_set pour channel %@ (pas sur 7TV?)", twitchUserID];
            return;
        }

        NSDictionary *parsed = [self parseEmoteSetJSON:emoteSet];
        if (!parsed.count) return;

        dispatch_barrier_async(self.emoteQueue, ^{
            self.channelEmotes = parsed;
            [self log:@"✅ %lu emotes du channel chargées depuis API", (unsigned long)parsed.count];
        });

        // Sauvegarder en cache (async)
        [self saveCacheForName:cacheName withEmotes:parsed];

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
        if (![name   isKindOfClass:[NSString class]]) name   = nil;
        if (![itemID isKindOfClass:[NSString class]]) itemID = nil;

        id rawData = item[@"data"];
        NSDictionary *data = [rawData isKindOfClass:[NSDictionary class]] ? rawData : nil;

        id rawEmoteID  = data[@"id"];
        NSString *emoteID = [rawEmoteID isKindOfClass:[NSString class]] ? rawEmoteID : itemID;

        id rawAnimated = data[@"animated"];
        BOOL animated  = [rawAnimated isKindOfClass:[NSNumber class]] && [rawAnimated boolValue];

        if (!name || !emoteID) continue;

        SevenTVEmote *emote = [[SevenTVEmote alloc] init];
        emote.emoteID    = emoteID;
        emote.emoteName  = name;
        emote.isAnimated = animated;
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
        id json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
        if (!json) return;

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
                });
                @synchronized(self.fetchingChannelIDs) {
                    if (oldID) [self.fetchingChannelIDs removeObject:oldID];
                }

                self.currentChannelTwitchID = broadcasterID;
                [self loadEmotesForChannelTwitchID:broadcasterID];
                break;
            }
        }
    });
}

- (NSString *)findBroadcasterIDInObject:(id)obj channelLogin:(NSString **)outLogin {
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
                        if ([rawLogin isKindOfClass:[NSString class]] && [rawLogin length] > 0)
                            *outLogin = rawLogin;
                    }
                    return foundID;
                }
            }
        }

        for (NSString *key in dict) {
            if ([key.lowercaseString containsString:@"broadcast"] ||
                [key.lowercaseString containsString:@"channel"]) {
                NSString *result = [self findBroadcasterIDInObject:dict[key] channelLogin:outLogin];
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
    return ([str rangeOfCharacterFromSet:
             [[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound);
}


// ============================================================
// MARK: - Injection des emotes 7TV dans les messages IRC (Fix C v1.4)
//
// Un paquet WebSocket peut contenir plusieurs lignes IRC séparées par \r\n.
// On traite chaque ligne indépendamment pour éviter les croisements de tags.
// ============================================================

- (NSString *)injectSevenTVEmotesIntoIRCMessage:(NSString *)rawMessage {
    if (!self.isEnabled || rawMessage.length == 0) return rawMessage;

    NSArray<NSString *> *lines = [rawMessage componentsSeparatedByString:@"\r\n"];

    if (lines.count == 1) {
        return [self injectIntoSingleIRCLine:rawMessage];
    }

    BOOL modified = NO;
    NSMutableArray<NSString *> *processed = [NSMutableArray arrayWithCapacity:lines.count];

    for (NSString *line in lines) {
        if (line.length == 0) { [processed addObject:line]; continue; }
        NSString *result = [self injectIntoSingleIRCLine:line];
        if (!modified && ![result isEqualToString:line]) modified = YES;
        [processed addObject:result];
    }

    return modified ? [processed componentsJoinedByString:@"\r\n"] : rawMessage;
}

- (NSString *)injectIntoSingleIRCLine:(NSString *)line {
    if (![line containsString:@"PRIVMSG"]) return line;

    NSRange privmsgRange = [line rangeOfString:@"PRIVMSG #"];
    if (privmsgRange.location == NSNotFound) return line;

    NSString *afterPrivmsg = [line substringFromIndex:privmsgRange.location + privmsgRange.length];
    NSRange colonRange = [afterPrivmsg rangeOfString:@" :"];
    if (colonRange.location == NSNotFound) return line;

    NSString *messageText = [[afterPrivmsg substringFromIndex:colonRange.location + 2]
                             stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (messageText.length == 0) return line;

    __block NSDictionary *global, *channel;
    dispatch_sync(self.emoteQueue, ^{
        global  = self.globalEmotes  ?: @{};
        channel = self.channelEmotes ?: @{};
    });

    NSMutableArray<NSString *> *emoteTags = [NSMutableArray array];
    NSUInteger currentPos = 0;

    for (NSString *word in [messageText componentsSeparatedByString:@" "]) {
        if (word.length == 0) { currentPos += 1; continue; }

        SevenTVEmote *emote = channel[word] ?: global[word];
        if (emote) {
            if (!emote.isAnimated || self.showAnimated) {
                NSUInteger start = currentPos;
                NSUInteger end   = currentPos + word.length - 1;
                NSString *tag = [NSString stringWithFormat:@"%@%@:%lu-%lu",
                                 S7TV_EMOTE_ID_PREFIX, emote.emoteID,
                                 (unsigned long)start, (unsigned long)end];
                [emoteTags addObject:tag];
                [self log:@"🎭 Emote trouvée: %@ (ID: %@) pos:%lu-%lu",
                 word, emote.emoteID, (unsigned long)start, (unsigned long)end];
            }
        }
        currentPos += word.length + 1;
    }

    if (emoteTags.count == 0) return line;

    [self log:@"💉 Injection de %lu emote(s): %@",
     (unsigned long)emoteTags.count, [emoteTags componentsJoinedByString:@" | "]];

    NSString *result = [self buildIRCLineWithEmotes:[emoteTags componentsJoinedByString:@","]
                                             inLine:line];

    [self log:@"🏷 tag final -> %@",
     [result substringToIndex:MIN((NSUInteger)150, result.length)]];

    return result;
}

- (NSString *)buildIRCLineWithEmotes:(NSString *)newEmotesStr inLine:(NSString *)line {
    NSRange emoteTagRange = [line rangeOfString:@"emotes="];

    if (emoteTagRange.location != NSNotFound) {
        NSUInteger insertPos  = emoteTagRange.location + emoteTagRange.length;
        NSString *afterEmotes = [line substringFromIndex:insertPos];

        NSRange sc = [afterEmotes rangeOfString:@";"];
        NSRange sp = [afterEmotes rangeOfString:@" "];
        NSUInteger limit = afterEmotes.length;
        if (sc.location != NSNotFound) limit = sc.location;
        if (sp.location != NSNotFound && sp.location < limit) limit = sp.location;

        NSString *prefix         = [line substringToIndex:insertPos];
        NSString *existingEmotes = [afterEmotes substringToIndex:limit];
        NSString *suffix         = [afterEmotes substringFromIndex:limit];

        NSString *combined = existingEmotes.length > 0
            ? [NSString stringWithFormat:@"%@,%@", existingEmotes, newEmotesStr]
            : newEmotesStr;

        return [NSString stringWithFormat:@"%@%@%@", prefix, combined, suffix];

    } else {
        if ([line hasPrefix:@"@"]) {
            return [NSString stringWithFormat:@"@emotes=%@;%@", newEmotesStr,
                    [line substringFromIndex:1]];
        }
        return [NSString stringWithFormat:@"@emotes=%@ %@", newEmotesStr, line];
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
    return [NSURL URLWithString:
            [NSString stringWithFormat:@"%@/%@/4x.webp", S7TV_CDN_BASE, emote.emoteID]];
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
                    for (UIWindow *w in ((UIWindowScene *)scene).windows)
                        if (w.isKeyWindow) { window = w; break; }
                }
            }
        }
        if (!window) window = [UIApplication sharedApplication].windows.firstObject;
        if (!window) return;

        CGFloat size = 44.0, margin = 16.0;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(window.bounds.size.width  - size - margin,
                               window.bounds.size.height - size - margin - 80.0,
                               size, size);
        btn.backgroundColor     = [UIColor colorWithRed:0.35 green:0.13 blue:0.86 alpha:0.88];
        btn.layer.cornerRadius  = size / 2.0;
        btn.layer.shadowColor   = [UIColor blackColor].CGColor;
        btn.layer.shadowOffset  = CGSizeMake(0, 2);
        btn.layer.shadowRadius  = 4;
        btn.layer.shadowOpacity = 0.4;
        [btn setTitle:@"7TV" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [btn addTarget:self action:@selector(settingsButtonTapped:)
      forControlEvents:UIControlEventTouchUpInside];
        [btn addGestureRecognizer:[[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleSettingsButtonDrag:)]];
        [window addSubview:btn];
        self.settingsButton = btn;
    });
}

- (void)settingsButtonTapped:(UIButton *)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        SevenTVSettingsController *vc = [[SevenTVSettingsController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [[self topViewController] presentViewController:nav animated:YES completion:nil];
    });
}

- (void)handleSettingsButtonDrag:(UIPanGestureRecognizer *)gesture {
    UIView *btn = gesture.view, *parent = btn.superview;
    if (!parent) return;
    CGPoint t = [gesture translationInView:parent];
    CGFloat hw = btn.bounds.size.width/2, hh = btn.bounds.size.height/2;
    btn.center = CGPointMake(
        MAX(hw, MIN(parent.bounds.size.width  - hw, btn.center.x + t.x)),
        MAX(hh, MIN(parent.bounds.size.height - hh, btn.center.y + t.y)));
    [gesture setTranslation:CGPointZero inView:parent];
}

- (UIViewController *)topViewController {
    UIWindow *window = nil;
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]])
                for (UIWindow *w in ((UIWindowScene *)scene).windows)
                    if (w.isKeyWindow) { window = w; break; }
        }
    }
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}


// ============================================================
// MARK: - Logging
// ============================================================

- (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@",
                      [fmt stringFromDate:[NSDate date]], msg];

    [self.logLock lock];
    [self.logBuffer addObject:line];
    if (self.logBuffer.count > S7TV_LOG_BUFFER_MAX) {
        [self.logBuffer removeObjectsInRange:
         NSMakeRange(0, self.logBuffer.count - S7TV_LOG_BUFFER_MAX)];
    }
    [self.logLock unlock];

    if (self.debugLogging) NSLog(@"[TwitchSevenTV] %@", msg);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:S7TVLogsDidUpdateNotification
                          object:self userInfo:@{@"line": line}];
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
                          object:self userInfo:@{@"cleared": @YES}];
    });
}

@end
