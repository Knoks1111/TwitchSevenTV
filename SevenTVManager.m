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
 *   Fix F — Stratégie cache-first + refresh arrière-plan.
 *   Fix G — Protection anti-doublons affinée (fetchingChannelIDs).
 *
 * CORRECTIFS v1.6 — Format IRC + Positions:
 *   Fix H — Trimming messageText: on ne retire plus que \r\n en fin de message,
 *            jamais les espaces de début (qui décaleraient toutes les positions).
 *
 *   Fix I — Format tag emotes= conforme au standard Twitch IRC:
 *              • occurrences du MÊME emote ID → séparées par ","
 *                  ex: ID:0-4,10-14
 *              • emote IDs DIFFÉRENTS → séparés par "/"
 *                  ex: ID1:0-4/ID2:10-14
 *            L'ancien code joinait tout avec "," ce qui rendait les messages
 *            mixtes (texte + plusieurs emotes) malformés.
 *
 *   Fix J — Séparateur "/" lors de la fusion avec des emotes Twitch existantes.
 *            L'ancien "," faisait croire à Twitch que notre emote 7TV était
 *            une 2ème occurrence de l'emote Twitch précédente, cachant du texte.
 *
 *   Fix K — Écriture cache: retry automatique avec recréation du dossier si iOS
 *            a purgé Library/Caches/s7tv/ entre deux lancements.
 *
 * NOUVEAUTÉS v1.7 — Prefetch massif au JOIN:
 *   Fix L — Au JOIN d'un channel (et au setup pour les globales), toutes les
 *            images d'emotes sont téléchargées en arrière-plan dans NSURLCache
 *            (20 downloads simultanés, DISPATCH_QUEUE_PRIORITY_HIGH).
 *            Résultat: dès la 1ère occurrence d'une emote dans le chat,
 *            SevenTVURLProtocol trouve l'image en cache → réponse synchrone
 *            → CoreText a l'image pendant le calcul du layout → zéro case vide,
 *            zéro blocage de livraison de message.
 *            Le prefetch est idempotent: les emotes déjà en cache sont skipées.
 */

#import "SevenTVManager.h"
#import "SevenTVSettingsController.h"
#import "SevenTVURLProtocol.h"
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
@property (nonatomic, weak)   UIButton *settingsButton;
// Fenêtre dédiée au bouton flottant (strong = reste en vie toute la session)
@property (nonatomic, strong) UIWindow *floatingWindow;

// Buffer de logs in-app
@property (nonatomic, strong) NSMutableArray<NSString *> *logBuffer;
@property (nonatomic, strong) NSLock *logLock;

// Dossier racine du cache JSON (créé à la demande)
@property (nonatomic, strong) NSString *cacheDirectory;

// Timer heartbeat CDN — envoie un HEAD toutes les 20s pour garder
// la connexion TCP/TLS keep-alive ouverte vers cdn.7tv.app.
@property (nonatomic, strong) NSTimer *cdnHeartbeatTimer;

// Prefetch massif (Fix L v1.7)
// Télécharge toutes les images d'un dictionnaire d'emotes en arrière-plan.
// label : libellé affiché dans les logs ("globales", "channel", etc.)
// Idempotent : les emotes déjà en cache sont skipées sans réseau.
- (void)_prefetchAllEmotes:(NSDictionary<NSString *, SevenTVEmote *> *)emotes
                     label:(NSString *)label;

@end


// ============================================================
// MARK: - SevenTVFloatingWindow
//
// UIWindow dont le hitTest ne capte les touches QUE si une
// vraie sous-vue (le bouton 7TV) est touchée.
// Si le fond transparent est touché → retourne nil → iOS
// transmet le touch à la fenêtre Twitch en dessous.
// ============================================================
@interface SevenTVFloatingWindow : UIWindow
@end

@implementation SevenTVFloatingWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // On ne capture la touche QUE si elle tombe sur le bouton ou l'un
    // de ses sous-vues (label, etc.). Le fond transparent (self) et
    // la rootVC.view passent toujours à Twitch → nil = ignore.
    if (hit == nil || hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}
@end


// ============================================================
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
            // Retry: le dossier a peut-être été purgé par iOS entre temps
            [[NSFileManager defaultManager]
                createDirectoryAtPath:[path stringByDeletingLastPathComponent]
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];
            ok = [data writeToFile:path atomically:YES];
            if (!ok) {
                [self log:@"⚠️ Écriture cache échouée (retry): %@", path.lastPathComponent];
            }
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
        // Fix L: précharger les images immédiatement depuis le cache JSON
        [self _prefetchAllEmotes:cachedGlobal label:@"globales (cache)"];
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

    // 3. Préchauffer la connexion TCP/TLS vers cdn.7tv.app
    //    → élimine le délai de 4-5s sur la 1ère emote chargée.
    //    On le fait systématiquement, cache frais ou non.
    [SevenTVURLProtocol prewarmCDNConnection];
    [self log:@"🔥 Préchauffage connexion CDN lancé"];
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

        // Fix L: précharger toutes les images des emotes globales
        [self _prefetchAllEmotes:parsed label:@"globales (API)"];

    }] resume];
}


// ============================================================
// MARK: - Chargement des emotes d'un channel par nom
// ============================================================

- (void)loadEmotesForChannelName:(NSString *)channelName {
    if (!channelName.length) return;
    [self log:@"Channel rejoint: %@, recherche ID Twitch...", channelName];
    self.currentChannelName = channelName;

    // Préchauffer la connexion CDN maintenant — les messages arrivent
    // ~1-2s après le JOIN, donc la connexion sera chaude à temps.
    [SevenTVURLProtocol prewarmCDNConnection];
    [self log:@"🔥 Prewarm CDN au JOIN de %@", channelName];

    // Démarrer (ou redémarrer) le heartbeat pour garder la connexion vivante.
    [self startCDNHeartbeat];

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
// MARK: - Heartbeat CDN
//
// Envoie un HEAD toutes les 20s vers cdn.7tv.app pour garder
// la connexion TCP/TLS keep-alive ouverte.
// iOS ferme les connexions inactives après ~30s → sans heartbeat,
// la 1ère emote après une pause repart à froid.
// Le timer est invalidé et recréé à chaque JOIN de channel,
// ce qui remet aussi le compteur à zéro.
// ============================================================

- (void)startCDNHeartbeat {
    // Invalider l'ancien timer s'il existe (changement de channel, etc.)
    [self.cdnHeartbeatTimer invalidate];

    // NSTimer doit tourner sur le main thread (runloop main)
    dispatch_async(dispatch_get_main_queue(), ^{
        self.cdnHeartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:20.0
                                                                  target:self
                                                                selector:@selector(cdnHeartbeatTick)
                                                                userInfo:nil
                                                                 repeats:YES];
        // Tolérance de 2s pour économiser la batterie (iOS peut grouper les timers)
        self.cdnHeartbeatTimer.tolerance = 2.0;
    });
}

- (void)cdnHeartbeatTick {
    [SevenTVURLProtocol prewarmCDNConnection];
    // Log volontairement absent pour ne pas polluer le buffer —
    // activer uniquement en debug si besoin:
    // [self log:@"💓 CDN heartbeat"];
}


// ============================================================
// MARK: - Prefetch massif (Fix L v1.7)
//
// Objectif : remplir NSURLCache avec TOUTES les images du set
// dès que les emotes JSON sont connues — avant que le chat arrive.
//
// Stratégie :
//   • 20 downloads simultanés (DISPATCH_QUEUE_PRIORITY_HIGH)
//   • dispatch_semaphore pour brider la concurrence
//   • isEmoteIDCached: check synchrone → skip réseau si déjà là
//   • Log tous les 50 emotes + à la fin pour suivre la progression
//   • Entièrement fire-and-forget : n'affecte jamais la livraison IRC
// ============================================================

- (void)_prefetchAllEmotes:(NSDictionary<NSString *, SevenTVEmote *> *)emotes
                     label:(NSString *)label {
    if (!emotes.count) return;

    NSArray<SevenTVEmote *> *allEmotes = emotes.allValues;
    NSUInteger total = allEmotes.count;

    [self log:@"🚀 Prefetch %@ — %lu emotes", label, (unsigned long)total];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{

        // 20 downloads en parallèle — bon compromis débit / saturation réseau.
        // Augmenter à 30+ si le réseau est rapide, baisser à 10 sur réseau limité.
        dispatch_semaphore_t sem = dispatch_semaphore_create(20);
        dispatch_group_t group  = dispatch_group_create();

        // Compteur thread-safe pour les logs de progression
        __block NSUInteger done    = 0;
        __block NSUInteger skipped = 0;
        NSLock *counterLock = [[NSLock alloc] init];

        for (SevenTVEmote *emote in allEmotes) {
            // Skip immédiat si déjà en cache — zéro réseau
            if ([SevenTVURLProtocol isEmoteIDCached:emote.emoteID]) {
                [counterLock lock];
                done++;
                skipped++;
                [counterLock unlock];
                continue;
            }

            // Brider la concurrence
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            dispatch_group_enter(group);

            NSString *emoteID = emote.emoteID; // capture forte
            [SevenTVURLProtocol prefetchEmoteID:emoteID completion:^{
                dispatch_semaphore_signal(sem);
                dispatch_group_leave(group);

                [counterLock lock];
                NSUInteger current = ++done;
                [counterLock unlock];

                // Log tous les 50 + au dernier
                if (current % 50 == 0 || current == total) {
                    [self log:@"📦 Prefetch %@ — %lu/%lu (skip:%lu)",
                     label, (unsigned long)current,
                     (unsigned long)total, (unsigned long)skipped];
                }
            }];
        }

        // Attendre la fin de tous les downloads avant le log final
        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW,
                                                 60LL * NSEC_PER_SEC)); // timeout 60s
        [self log:@"✅ Prefetch %@ terminé — %lu en cache, %lu déjà présents",
         label,
         (unsigned long)(total - skipped),
         (unsigned long)skipped];
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
        // Fix L: précharger les images immédiatement — le chat arrive dans secondes
        [self _prefetchAllEmotes:cached label:@"channel (cache)"];
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

        // Fix L: précharger toutes les images — elles seront prêtes pour les messages suivants
        [self _prefetchAllEmotes:parsed label:@"channel (API)"];

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

    // ── Fix H: ne PAS toucher les espaces de début de message (ils décalent les positions)
    // On retire uniquement \r et \n en fin de chaîne.
    NSString *messageText = [afterPrivmsg substringFromIndex:colonRange.location + 2];
    while (messageText.length > 0) {
        unichar last = [messageText characterAtIndex:messageText.length - 1];
        if (last == '\r' || last == '\n') {
            messageText = [messageText substringToIndex:messageText.length - 1];
        } else {
            break;
        }
    }
    if (messageText.length == 0) return line;

    __block NSDictionary *global, *channel;
    dispatch_sync(self.emoteQueue, ^{
        global  = self.globalEmotes  ?: @{};
        channel = self.channelEmotes ?: @{};
    });

    // emotesMap: emoteID (avec préfixe) → tableau de positions "start-end"
    // Permet de regrouper les occurrences du même ID pour le format Twitch:
    //   même ID → ID:pos1,pos2       (virgule entre les positions)
    //   ID différents → ID1:pos1/ID2:pos2  (slash entre les IDs)
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *emotesMap =
        [NSMutableDictionary dictionary];
    // Ordre d'insertion conservé pour la reproductibilité du tag final
    NSMutableArray<NSString *> *emoteIDOrder = [NSMutableArray array];

    NSUInteger currentPos = 0;

    for (NSString *word in [messageText componentsSeparatedByString:@" "]) {
        if (word.length == 0) { currentPos += 1; continue; }

        SevenTVEmote *emote = channel[word] ?: global[word];
        if (emote) {
            if (!emote.isAnimated || self.showAnimated) {
                NSUInteger start = currentPos;
                NSUInteger end   = currentPos + word.length - 1;
                NSString *fakeID  = [NSString stringWithFormat:@"%@%@",
                                     S7TV_EMOTE_ID_PREFIX, emote.emoteID];
                NSString *posStr  = [NSString stringWithFormat:@"%lu-%lu",
                                     (unsigned long)start, (unsigned long)end];

                if (!emotesMap[fakeID]) {
                    emotesMap[fakeID] = [NSMutableArray array];
                    [emoteIDOrder addObject:fakeID];
                }
                [emotesMap[fakeID] addObject:posStr];

                [self log:@"🎭 Emote trouvée: %@ (ID: %@) pos:%lu-%lu",
                 word, emote.emoteID, (unsigned long)start, (unsigned long)end];
            }
        }
        currentPos += word.length + 1;
    }

    if (emotesMap.count == 0) return line;

    // ── Fix I: construire le tag emotes= au format correct Twitch ───────────
    // Format: ID1:start1-end1,start2-end2/ID2:start3-end3
    NSMutableArray<NSString *> *emoteEntries = [NSMutableArray arrayWithCapacity:emoteIDOrder.count];
    for (NSString *eid in emoteIDOrder) {
        NSString *positions = [emotesMap[eid] componentsJoinedByString:@","];
        [emoteEntries addObject:[NSString stringWithFormat:@"%@:%@", eid, positions]];
    }
    // Différents emote IDs séparés par "/" (format Twitch officiel)
    NSString *newEmotesStr = [emoteEntries componentsJoinedByString:@"/"];

    [self log:@"💉 Injection de %lu emote(s): %@",
     (unsigned long)emoteIDOrder.count, newEmotesStr];

    NSString *result = [self buildIRCLineWithEmotes:newEmotesStr inLine:line];

    // ── Logging: afficher la valeur complète du tag emotes= ─────────────────
    NSRange emoteTagInResult = [result rangeOfString:@"emotes="];
    if (emoteTagInResult.location != NSNotFound) {
        NSString *afterTag = [result substringFromIndex:emoteTagInResult.location];
        NSRange scInResult = [afterTag rangeOfString:@";"];
        NSRange spInResult = [afterTag rangeOfString:@" "];
        NSUInteger endTag  = afterTag.length;
        if (scInResult.location != NSNotFound) endTag = scInResult.location;
        if (spInResult.location != NSNotFound && spInResult.location < endTag) endTag = spInResult.location;
        [self log:@"🏷 tag final -> %@", [afterTag substringToIndex:endTag]];
    } else {
        [self log:@"🏷 tag final (150) -> %@",
         [result substringToIndex:MIN((NSUInteger)150, result.length)]];
    }

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

        // ── Fix J: "/" pour séparer des emote IDs différents (standard Twitch)
        // "," sépare des occurrences du MÊME ID — ce que Twitch attendait avant
        NSString *combined = existingEmotes.length > 0
            ? [NSString stringWithFormat:@"%@/%@", existingEmotes, newEmotesStr]
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

        // ── Trouver la UIWindowScene ──────────────────────────────────────────
        UIWindowScene *windowScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                windowScene = (UIWindowScene *)scene;
                break;
            }
        }

        // ── Créer la fenêtre flottante ────────────────────────────────────────
        // Une UIWindow dédiée à windowLevel StatusBar+1 flotte au-dessus de
        // TOUTES les pages de Twitch (navigation, stream, chat, settings...).
        // Contrairement à un addSubview:keyWindow, elle n'est jamais couverte
        // par les transitions de navigation.
        SevenTVFloatingWindow *floatingWin;
        if (windowScene) {
            floatingWin = [[SevenTVFloatingWindow alloc] initWithWindowScene:windowScene];
        } else {
            floatingWin = [[SevenTVFloatingWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        floatingWin.windowLevel     = UIWindowLevelStatusBar + 1;
        floatingWin.backgroundColor = [UIColor clearColor];
        floatingWin.hidden          = NO;

        // rootViewController requis sous iOS 13+
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        floatingWin.rootViewController = rootVC;

        self.floatingWindow = floatingWin;

        // ── Créer le bouton ───────────────────────────────────────────────────
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat size = 44.0, margin = 16.0;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(screen.size.width  - size - margin,
                               screen.size.height - size - margin - 80.0,
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

        [rootVC.view addSubview:btn];
        self.settingsButton = btn;

        [self log:@"✅ Bouton 7TV dans UIWindow flottante (level %.0f)",
            (double)floatingWin.windowLevel];
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
