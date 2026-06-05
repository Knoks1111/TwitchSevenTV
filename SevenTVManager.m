/*
 * SevenTVManager.m
 * Implémentation du gestionnaire 7TV.
 *
 * CORRECTIFS v1.4:
 *   Fix C — Injection IRC multi-lignes.
 *   Fix D — Logs de diagnostic étendus.
 *
 * NOUVEAUTÉS v1.5 — Cache & Préchargement:
 *   Fix E — Cache fichier JSON.
 *   Fix F — Stratégie cache-first + refresh arrière-plan.
 *   Fix G — Protection anti-doublons (fetchingChannelIDs).
 *
 * CORRECTIFS v1.6 — Format IRC + Positions:
 *   Fix H — Trimming messageText (\r\n only).
 *   Fix I — Format tag emotes= conforme Twitch IRC.
 *   Fix J — Séparateur "/" entre IDs différents.
 *   Fix K — Écriture cache: retry si dossier purgé par iOS.
 *
 * NOUVEAUTÉS v1.7 — Prefetch massif au JOIN:
 *   Fix L — Au JOIN, toutes les images d'emotes sont téléchargées en
 *            arrière-plan (20 downloads simultanés, HIGH priority).
 *            Guard de déduplication (_activePrefetchKeys) : le même set
 *            ne peut être prefetché qu'une seule fois à la fois, même si
 *            loadEmotesForChannelTwitchID: est appelé plusieurs fois de
 *            suite (ROOMSTATE + GQL + timeout 5s).
 *            Résultat : zéro doublon, zéro contention réseau.
 */

#import "SevenTVManager.h"
#import "SevenTVSettingsController.h"
#import "SevenTVURLProtocol.h"
#import "SevenTVLogo.h"
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

// Picker d'emotes inline (affiché au-dessus de la barre de saisie)
@property (nonatomic, strong) UIView              *emotePickerView;
@property (nonatomic, weak)   UIView              *emotePickerTextField;
@property (nonatomic, strong) UICollectionView    *emoteCollectionView;
@property (nonatomic, strong) UITextField         *emoteSearchField;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerAllEmotes;

// Favoris : IDs 7TV des emotes mise en favoris (persisté dans NSUserDefaults)
@property (nonatomic, strong) NSMutableSet<NSString *> *favoriteEmoteIDs;
// Arrays filtrés pour l'affichage dans le picker (2 sections)
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerFavoriteEmotes;
@property (nonatomic, strong) NSArray<SevenTVEmote *> *emotePickerOtherEmotes;

// Buffer de logs in-app
@property (nonatomic, strong) NSMutableArray<NSString *> *logBuffer;
@property (nonatomic, strong) NSLock *logLock;

// Dossier racine du cache JSON (créé à la demande)
@property (nonatomic, strong) NSString *cacheDirectory;

// Timer heartbeat CDN — envoie un HEAD toutes les 20s pour garder
// la connexion TCP/TLS keep-alive ouverte vers cdn.7tv.app.
@property (nonatomic, strong) NSTimer *cdnHeartbeatTimer;

// Guard de déduplication pour _prefetchAllEmotes:setKey:label: (Fix L v1.7)
// Clé = twitchUserID pour les channels, "global" pour les globales.
// Protégé par @synchronized(self).
@property (nonatomic, strong) NSMutableSet<NSString *> *activePrefetchKeys;

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
        _fetchingChannelIDs  = [NSMutableSet set];
        _activePrefetchKeys  = [NSMutableSet set];

        _emoteQueue  = dispatch_queue_create("tv.s7tv.emote-queue",  DISPATCH_QUEUE_CONCURRENT);
        _fileIOQueue = dispatch_queue_create("tv.s7tv.file-io-queue", DISPATCH_QUEUE_SERIAL);

        _logBuffer = [NSMutableArray arrayWithCapacity:256];
        _logLock   = [[NSLock alloc] init];

        _favoriteEmoteIDs        = [NSMutableSet set];
        _emotePickerFavoriteEmotes = @[];
        _emotePickerOtherEmotes    = @[];

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
        // Dimensions 1x (optionnel — absent dans les anciennes entrées cache)
        id dw = d[@"w"], dh = d[@"h"];
        if ([dw isKindOfClass:[NSNumber class]]) e.width  = [dw integerValue];
        if ([dh isKindOfClass:[NSNumber class]]) e.height = [dh integerValue];
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
        // Inclure les dimensions si disponibles (rétrocompatible: champ absent = 0)
        if (e.width > 0 && e.height > 0) {
            emotesDict[name] = @{ @"id": e.emoteID, @"a": @(e.isAnimated),
                                  @"w": @(e.width),  @"h": @(e.height) };
        } else {
            emotesDict[name] = @{ @"id": e.emoteID, @"a": @(e.isAnimated) };
        }
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
        [self _prefetchAllEmotes:cachedGlobal setKey:@"global" label:@"globales (cache)"];
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
    // Charger les favoris (array d'IDs 7TV)
    NSArray *savedFavs = [prefs arrayForKey:@"s7tv_favorites"];
    if (savedFavs) {
        _favoriteEmoteIDs = [NSMutableSet setWithArray:savedFavs];
    }
}

- (void)savePreferences {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setBool:self.isEnabled    forKey:@"s7tv_enabled"];
    [prefs setBool:self.showAnimated forKey:@"s7tv_animated"];
    [prefs setBool:self.debugLogging forKey:@"s7tv_debug"];
    [prefs synchronize];
}

- (void)_saveFavorites {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    [prefs setObject:self.favoriteEmoteIDs.allObjects forKey:@"s7tv_favorites"];
    [prefs synchronize];
}

- (void)setIsEnabled:(BOOL)v    { _isEnabled    = v; [self savePreferences]; }
- (void)setShowAnimated:(BOOL)v { _showAnimated  = v; [self savePreferences]; }
- (void)setDebugLogging:(BOOL)v {
    _debugLogging  = v;
    [self savePreferences];
    // Synchroniser le tap logger avec l'état des logs
    extern BOOL s_tapLogEnabled;
    s_tapLogEnabled = v;
    [self log:@"👆 Tap logger %@", v ? @"activé" : @"désactivé"];
}


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

        [self saveCacheForName:@"global" withEmotes:parsed];
        [self _prefetchAllEmotes:parsed setKey:@"global" label:@"globales (API)"];

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

    // ── Fix cache: lookup immédiat du twitchID depuis le mapping sauvé ───────
    // Première visite : pas de mapping → attend le ROOMSTATE (< 200ms).
    // Visites suivantes : l'ID est connu → prefetch et cache démarre AVANT
    // le ROOMSTATE, les emotes sont prêtes dès le 1er message du chat.
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSDictionary *channelIDMap = [prefs dictionaryForKey:@"s7tv_channel_id_map"];
    NSString *cachedTwitchID = channelIDMap[channelName.lowercaseString];

    if (cachedTwitchID.length > 0) {
        [self log:@"⚡️ twitchID en cache pour %@: %@ → prefetch immédiat",
         channelName, cachedTwitchID];
        // Vider les emotes du channel précédent AVANT de charger les nouvelles.
        // Sans ce reset, un message ultra-rapide pourrait injecter une emote
        // de l'ancien channel pendant les ~100ms avant que loadEmotesForChannelTwitchID:
        // ne soit terminé.
        dispatch_barrier_async(self.emoteQueue, ^{
            self.channelEmotes = @{};
        });
        self.currentChannelTwitchID = cachedTwitchID;
        [self loadEmotesForChannelTwitchID:cachedTwitchID];
        // Pas de dispatch_after nécessaire : le ROOMSTATE confirmera (ou corrigera)
        // l'ID quelques ms plus tard via s7tv_handleRoomState.
        return;
    }

    // Première visite : pas de mapping → attendre le ROOMSTATE.
    // Timeout de sécurité à 5s au cas où le ROOMSTATE n'arriverait pas.
    [self log:@"⏳ Pas de twitchID en cache pour %@, attente ROOMSTATE...", channelName];
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
}


// ============================================================
// MARK: - Prefetch massif (Fix L v1.7)
//
// setKey  : clé de dédup (@"global" ou twitchUserID du channel).
//           Si un prefetch avec cette clé est déjà actif → skip immédiat.
//           La clé est retirée du set à la fin du prefetch, ce qui permet
//           un re-prefetch après changement du set (nouvelles emotes).
//
// Stratégie :
//   • 20 downloads simultanés — DISPATCH_QUEUE_PRIORITY_HIGH
//   • dispatch_semaphore pour brider la concurrence
//   • isEmoteIDCached: check synchrone → skip réseau si déjà en cache
//   • Log tous les 50 emotes + au final
// ============================================================

- (void)_prefetchAllEmotes:(NSDictionary<NSString *, SevenTVEmote *> *)emotes
                    setKey:(NSString *)setKey
                     label:(NSString *)label {
    if (!emotes.count || !setKey.length) return;

    // ── Déduplication : une seule session de prefetch par setKey ─────────────
    @synchronized(self) {
        if ([self.activePrefetchKeys containsObject:setKey]) {
            [self log:@"⏭️ Prefetch %@ déjà actif (key:%@), skip", label, setKey];
            return;
        }
        [self.activePrefetchKeys addObject:setKey];
    }

    NSArray<SevenTVEmote *> *allEmotes = emotes.allValues;
    NSUInteger total = allEmotes.count;
    [self log:@"🚀 Prefetch %@ — %lu emotes", label, (unsigned long)total];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{

        // 6 connexions simultanées — limite adaptée à HTTP/2 sur mobile.
        // cdn.7tv.app multiplex sur une seule connexion TCP : au-delà de ~8
        // streams le CDN throttle et iOS annule les requêtes en attente après
        // 10s → timeouts en cascade → emotes jamais cachées.
        // 6 est le sweet spot : débit maximal sans perte sur Wi-Fi et 4G/5G.
        dispatch_semaphore_t sem = dispatch_semaphore_create(6);
        dispatch_group_t group   = dispatch_group_create();

        __block NSUInteger done    = 0;
        __block NSUInteger skipped = 0;
        NSLock *lock = [[NSLock alloc] init];

        for (SevenTVEmote *emote in allEmotes) {
            // Skip si déjà en cache — zéro réseau
            if ([SevenTVURLProtocol isEmoteIDCached:emote.emoteID]) {
                [lock lock]; done++; skipped++; [lock unlock];
                continue;
            }

            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            dispatch_group_enter(group);

            NSString *eid = emote.emoteID;
            [SevenTVURLProtocol prefetchEmoteID:eid completion:^{
                dispatch_semaphore_signal(sem);
                dispatch_group_leave(group);

                [lock lock];
                NSUInteger current = ++done;
                [lock unlock];

                if (current % 50 == 0 || current == total) {
                    [self log:@"📦 Prefetch %@ — %lu/%lu (skip:%lu)",
                     label, (unsigned long)current,
                     (unsigned long)total, (unsigned long)skipped];
                }
            }];
        }

        // Attendre la fin (timeout 60s)
        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 60LL * NSEC_PER_SEC));

        [self log:@"✅ Prefetch %@ terminé — %lu téléchargés, %lu déjà en cache",
         label,
         (unsigned long)(total - skipped),
         (unsigned long)skipped];

        // Libérer la clé → permettre un re-prefetch si le set change
        @synchronized(self) {
            [self.activePrefetchKeys removeObject:setKey];
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
        [self _prefetchAllEmotes:cached setKey:twitchUserID label:@"channel (cache)"];
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

        [self saveCacheForName:cacheName withEmotes:parsed];
        [self _prefetchAllEmotes:parsed setKey:twitchUserID label:@"channel (API)"];

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

        // ── Dimensions 1x depuis data.host.files ──────────────────────────────
        // L'API 7TV v3 retourne un tableau de fichiers par taille (1x, 2x, 3x, 4x).
        // On prend le fichier "1x" : c'est la taille d'affichage cible en points.
        // Exemple pour KEKW : 1x = 28×28pt, 4x = 112×112px.
        NSInteger emoteW = 0, emoteH = 0;
        id rawHost = data[@"host"];
        if ([rawHost isKindOfClass:[NSDictionary class]]) {
            id rawFiles = rawHost[@"files"];
            if ([rawFiles isKindOfClass:[NSArray class]]) {
                for (NSDictionary *file in (NSArray *)rawFiles) {
                    if (![file isKindOfClass:[NSDictionary class]]) continue;
                    NSString *fname = file[@"name"];
                    // "1x.webp", "1x.avif", "1x.gif" → premier fichier 1x trouvé
                    if ([fname hasPrefix:@"1x"]) {
                        id fw = file[@"width"], fh = file[@"height"];
                        if ([fw isKindOfClass:[NSNumber class]]) emoteW = [fw integerValue];
                        if ([fh isKindOfClass:[NSNumber class]]) emoteH = [fh integerValue];
                        break;
                    }
                }
                // Fallback: si aucun fichier "1x" → utiliser le premier disponible
                if (emoteW == 0 && [(NSArray *)rawFiles count] > 0) {
                    NSDictionary *first = ((NSArray *)rawFiles)[0];
                    if ([first isKindOfClass:[NSDictionary class]]) {
                        id fw = first[@"width"], fh = first[@"height"];
                        if ([fw isKindOfClass:[NSNumber class]]) emoteW = [fw integerValue];
                        if ([fh isKindOfClass:[NSNumber class]]) emoteH = [fh integerValue];
                    }
                }
            }
        }

        SevenTVEmote *emote = [[SevenTVEmote alloc] init];
        emote.emoteID    = emoteID;
        emote.emoteName  = name;
        emote.isAnimated = animated;
        emote.width      = emoteW;
        emote.height     = emoteH;
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
// MARK: - Picker d'emotes 7TV
//
// Affiché au-dessus de la barre de saisie Twitch quand l'utilisateur
// tape sur le bouton 7TV intégré dans la barre.
// Interface : grille de cellules (emoji-like) + barre de recherche.
// Tap sur une emote → insère le nom dans le TextField.
// ============================================================

// ID de cellule pour la collection
static NSString *const kEmoteCellID = @"S7TVEmoteCell";

// Hauteur du picker
static const CGFloat kPickerHeight  = 280.0;
// Taille de chaque cellule par défaut (carré)
static const CGFloat kCellSize      = 40.0;

- (void)toggleEmotePickerForChatInputView:(UIView *)chatInputView {
    dispatch_async(dispatch_get_main_queue(), ^{
        // ── Si le picker est déjà visible → le fermer ─────────────────────────
        if (self.emotePickerView && !self.emotePickerView.isHidden) {
            [self _hideEmotePicker];
            return;
        }
        self.emotePickerTextField = chatInputView;
        [self _buildAndShowEmotePickerForView:chatInputView];
    });
}

- (void)_hideEmotePicker {
    [UIView animateWithDuration:0.2 animations:^{
        self.emotePickerView.alpha = 0;
        self.emotePickerView.transform = CGAffineTransformMakeTranslation(0, 20);
    } completion:^(BOOL done) {
        self.emotePickerView.hidden = YES;
        self.emotePickerView.alpha = 1;
        self.emotePickerView.transform = CGAffineTransformIdentity;
    }];
}

- (void)_buildAndShowEmotePickerForView:(UIView *)chatInputView {
    // ── Rassembler toutes les emotes (channel d'abord, puis globales) ──────
    __block NSDictionary *global, *channel;
    dispatch_sync(self.emoteQueue, ^{
        global  = self.globalEmotes  ?: @{};
        channel = self.channelEmotes ?: @{};
    });

    NSMutableArray<SevenTVEmote *> *all = [NSMutableArray array];
    // Channel en premier (plus pertinent)
    for (NSString *key in [channel.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)])
        [all addObject:channel[key]];
    for (NSString *key in [global.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        if (!channel[key]) [all addObject:global[key]]; // pas de doublons
    }
    self.emotePickerAllEmotes = [all copy];
    self.emotePickerEmotes    = self.emotePickerAllEmotes;
    [self _updatePickerArraysForSearch:@""];

    // ── Trouver la fenêtre clé ─────────────────────────────────────────────
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene *)scene).windows)
                if (w.isKeyWindow) { keyWindow = w; break; }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].windows.firstObject;
    if (!keyWindow) return;

    CGRect screenBounds = keyWindow.bounds;

    // ── Trouver la position Y du TextField dans la fenêtre ────────────────
    // Positionner le picker juste au-dessus de la ChatInputView
    CGRect tfFrame = chatInputView
        ? [chatInputView convertRect:chatInputView.bounds toView:keyWindow]
        : CGRectMake(0, keyWindow.bounds.size.height - 56, keyWindow.bounds.size.width, 56);
    CGFloat pickerY = tfFrame.origin.y - kPickerHeight - 4.0;
    if (pickerY < 0) pickerY = 0;

    CGRect pickerFrame = CGRectMake(0, pickerY, screenBounds.size.width, kPickerHeight);

    // ── Créer ou réutiliser le picker ─────────────────────────────────────
    if (!self.emotePickerView) {
        [self _createEmotePickerViewWithFrame:pickerFrame inWindow:keyWindow];
    } else {
        self.emotePickerView.frame = pickerFrame;
        [keyWindow addSubview:self.emotePickerView]; // re-attacher si nécessaire
    }

    // Reset la recherche
    self.emoteSearchField.text = @"";
    [self _updatePickerArraysForSearch:@""];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];

    // ── Afficher avec animation ────────────────────────────────────────────
    self.emotePickerView.hidden    = NO;
    self.emotePickerView.alpha     = 0;
    self.emotePickerView.transform = CGAffineTransformMakeTranslation(0, 20);
    [UIView animateWithDuration:0.22
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.emotePickerView.alpha     = 1;
        self.emotePickerView.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)_createEmotePickerViewWithFrame:(CGRect)frame inWindow:(UIWindow *)window {

    // ── Couleurs dans le style Twitch dark ─────────────────────────────────
    UIColor *bgColor     = [UIColor colorWithRed:0.13 green:0.13 blue:0.15 alpha:1.0]; // #211F26
    UIColor *headerColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1.0]; // plus sombre
    UIColor *sepColor    = [UIColor colorWithRed:0.25 green:0.25 blue:0.28 alpha:1.0];
    UIColor *textColor   = [UIColor whiteColor];
    UIColor *subColor    = [UIColor colorWithRed:0.60 green:0.60 blue:0.65 alpha:1.0];
    UIColor *searchBg    = [UIColor colorWithRed:0.20 green:0.20 blue:0.23 alpha:1.0];

    // ── Conteneur principal ────────────────────────────────────────────────
    UIView *picker = [[UIView alloc] initWithFrame:frame];
    picker.backgroundColor    = bgColor;
    picker.layer.shadowColor  = [UIColor blackColor].CGColor;
    picker.layer.shadowOffset = CGSizeMake(0, -3);
    picker.layer.shadowRadius = 8;
    picker.layer.shadowOpacity = 0.35;
    // Coins arrondis en haut uniquement
    picker.layer.cornerRadius = 12;
    picker.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    picker.clipsToBounds = YES;
    self.emotePickerView = picker;

    // ── Header ─────────────────────────────────────────────────────────────
    CGFloat headerH = 48.0;
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, headerH)];
    headerView.backgroundColor = headerColor;
    headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    // Séparateur bas du header
    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, headerH - 0.5, frame.size.width, 0.5)];
    sep.backgroundColor = sepColor;
    sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [headerView addSubview:sep];

    // Logo 7TV (PNG base64, ratio correct) + label "Emotes"
    // PNG : 76×56 px → @2x = 38×28 pt
    NSData *_logoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *_logoImg = [UIImage imageWithData:_logoData scale:2.0];
    // UIImageView centré verticalement dans le header, respecte le ratio naturel du PNG
    CGFloat _logoW = _logoImg ? _logoImg.size.width  : 38.0; // 38 pt
    CGFloat _logoH = _logoImg ? _logoImg.size.height : 28.0; // 28 pt
    CGFloat _logoY = (headerH - _logoH) / 2.0;
    UIImageView *_logoIV = [[UIImageView alloc] initWithFrame:CGRectMake(12, _logoY, _logoW, _logoH)];
    _logoIV.image = _logoImg;
    _logoIV.contentMode = UIViewContentModeScaleAspectFit;
    [headerView addSubview:_logoIV];

    // Label "Emotes" à droite du logo
    CGFloat _lblX = 12 + _logoW + 4;
    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(_lblX, 0, 80, headerH)];
    titleLbl.text = @"Emotes";
    titleLbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    titleLbl.textColor = textColor;
    [headerView addSubview:titleLbl];

    // Champ de recherche
    // X = logo(38) + gap(4) + label(~60) + gap(6) = ~108 → on prend 110
    UITextField *search = [[UITextField alloc] initWithFrame:
        CGRectMake(110, 9, frame.size.width - 110 - 48, 30)];
    search.placeholder     = @"Rechercher une emote…";
    search.font            = [UIFont systemFontOfSize:13];
    search.returnKeyType   = UIReturnKeyDone;
    search.clearButtonMode = UITextFieldViewModeWhileEditing;
    search.backgroundColor = searchBg;
    search.textColor       = textColor;
    search.layer.cornerRadius = 8;
    search.clipsToBounds   = YES;
    // Padding gauche
    search.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,10,1)];
    search.leftViewMode = UITextFieldViewModeAlways;
    search.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Rechercher…"
            attributes:@{NSForegroundColorAttributeName: subColor}];
    search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [search addTarget:self action:@selector(_emoteSearchChanged:)
     forControlEvents:UIControlEventEditingChanged];
    self.emoteSearchField = search;
    [headerView addSubview:search];

    // Bouton fermer ×
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(frame.size.width - 44, 0, 44, headerH);
    closeBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    UIImageSymbolConfiguration *xCfg = [UIImageSymbolConfiguration
        configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
    [closeBtn setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:xCfg]
              forState:UIControlStateNormal];
    closeBtn.tintColor = subColor;
    [closeBtn addTarget:self action:@selector(_emotePickerCloseTapped)
       forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:closeBtn];

    [picker addSubview:headerView];

    // ── Collection View — SCROLL VERTICAL UNIQUEMENT ───────────────────────
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection        = UICollectionViewScrollDirectionVertical;
    layout.itemSize               = CGSizeMake(kCellSize, kCellSize);
    layout.minimumInteritemSpacing = 1;
    layout.minimumLineSpacing      = 1;
    layout.sectionInset = UIEdgeInsetsMake(2, 2, 2, 2);
    layout.headerReferenceSize = CGSizeMake(frame.size.width, 28.0);
    // itemSize est géré via collectionView:layout:sizeForItemAtIndexPath:

    UICollectionView *cv = [[UICollectionView alloc]
        initWithFrame:CGRectMake(0, headerH, frame.size.width, kPickerHeight - headerH)
 collectionViewLayout:layout];
    // Le fond du cv sert de "mini bordure" entre les cellules transparentes
    cv.backgroundColor        = sepColor;
    cv.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cv.dataSource             = (id<UICollectionViewDataSource>)self;
    cv.delegate               = (id<UICollectionViewDelegate>)self;
    // SCROLL VERTICAL — pas d'horizontal
    cv.alwaysBounceVertical   = YES;
    cv.alwaysBounceHorizontal = NO;
    cv.showsHorizontalScrollIndicator = NO;
    cv.showsVerticalScrollIndicator   = YES;

    [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:kEmoteCellID];
    [cv registerClass:[UICollectionReusableView class]
   forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
          withReuseIdentifier:@"S7TVSectionHeader"];
    self.emoteCollectionView = cv;

    // Long press → mettre en favori
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(_handleLongPressOnPicker:)];
    lp.minimumPressDuration = 0.5;
    [cv addGestureRecognizer:lp];

    [picker addSubview:cv];

    [window addSubview:picker];
}

// ── Recherche ──────────────────────────────────────────────────────────────

// ── Méthode centrale de filtrage : met à jour les 2 sections ──────────────

- (void)_updatePickerArraysForSearch:(NSString *)query {
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *lower = q.lowercaseString;

    NSMutableArray<SevenTVEmote *> *favs   = [NSMutableArray array];
    NSMutableArray<SevenTVEmote *> *others = [NSMutableArray array];

    for (SevenTVEmote *e in self.emotePickerAllEmotes) {
        BOOL matches = (q.length == 0) || [e.emoteName.lowercaseString containsString:lower];
        if (!matches) continue;
        if ([self.favoriteEmoteIDs containsObject:e.emoteID]) {
            [favs addObject:e];
        } else {
            [others addObject:e];
        }
    }
    self.emotePickerFavoriteEmotes = [favs copy];
    self.emotePickerOtherEmotes    = [others copy];
    // Maintenir emotePickerEmotes pour compatibilité
    self.emotePickerEmotes = self.emotePickerOtherEmotes;
}

- (void)_emoteSearchChanged:(UITextField *)field {
    NSString *query = field.text ?: @"";
    [self _updatePickerArraysForSearch:query];
    [self.emoteCollectionView reloadData];
    [self.emoteCollectionView setContentOffset:CGPointZero animated:NO];
}

// ── Long press → toggle favori ─────────────────────────────────────────────

- (void)_handleLongPressOnPicker:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;

    CGPoint pt = [gr locationInView:self.emoteCollectionView];
    NSIndexPath *ip = [self.emoteCollectionView indexPathForItemAtPoint:pt];
    if (!ip) return;

    SevenTVEmote *emote = [self _emoteForIndexPath:ip];
    if (!emote) return;

    BOOL isFav = [self.favoriteEmoteIDs containsObject:emote.emoteID];
    if (isFav) {
        [self.favoriteEmoteIDs removeObject:emote.emoteID];
        [self log:@"💔 Favori retiré : %@", emote.emoteName];
    } else {
        [self.favoriteEmoteIDs addObject:emote.emoteID];
        [self log:@"⭐ Favori ajouté : %@", emote.emoteName];
    }
    [self _saveFavorites];

    // Haptique
    UINotificationFeedbackGenerator *haptic = [[UINotificationFeedbackGenerator alloc] init];
    [haptic notificationOccurred:UINotificationFeedbackTypeSuccess];

    // Rebuild les arrays et recharger
    NSString *q = self.emoteSearchField.text ?: @"";
    [self _updatePickerArraysForSearch:q];
    [self.emoteCollectionView reloadData];
}

// ── Helper : emote à partir d'un indexPath (section 0=favs, 1=others) ──────

- (SevenTVEmote *)_emoteForIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        if ((NSUInteger)ip.item < self.emotePickerFavoriteEmotes.count)
            return self.emotePickerFavoriteEmotes[(NSUInteger)ip.item];
    } else {
        if ((NSUInteger)ip.item < self.emotePickerOtherEmotes.count)
            return self.emotePickerOtherEmotes[(NSUInteger)ip.item];
    }
    return nil;
}

- (void)_emotePickerCloseTapped {
    [self _hideEmotePicker];
}

// ── UICollectionViewDataSource ─────────────────────────────────────────────

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    return 2; // Section 0 = favoris, Section 1 = toutes les autres
}

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)self.emotePickerFavoriteEmotes.count;
    return (NSInteger)self.emotePickerOtherEmotes.count;
}

// ── Headers de section ────────────────────────────────────────────────────

- (UICollectionReusableView *)collectionView:(UICollectionView *)cv
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    UICollectionReusableView *header = [cv dequeueReusableSupplementaryViewOfKind:kind
                                                               withReuseIdentifier:@"S7TVSectionHeader"
                                                                      forIndexPath:indexPath];
    // Nettoyer
    for (UIView *sub in header.subviews) [sub removeFromSuperview];

    UIColor *sepColor  = [UIColor colorWithRed:0.25 green:0.25 blue:0.28 alpha:1.0];
    UIColor *textColor = [UIColor colorWithRed:0.60 green:0.60 blue:0.65 alpha:1.0];
    header.backgroundColor = [UIColor colorWithRed:0.13 green:0.13 blue:0.15 alpha:1.0];

    if (indexPath.section == 0 && self.emotePickerFavoriteEmotes.count > 0) {
        // Séparateur haut
        UIView *topSep = [[UIView alloc] initWithFrame:CGRectMake(8, 0, cv.bounds.size.width - 16, 0.5)];
        topSep.backgroundColor = sepColor;
        [header addSubview:topSep];

        // Étoile ★ violette style Twitch
        UIImageView *star = [[UIImageView alloc] initWithFrame:CGRectMake(14, 6, 13, 13)];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:10 weight:UIImageSymbolWeightBold];
        star.image = [UIImage systemImageNamed:@"star.fill" withConfiguration:cfg];
        star.tintColor = [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]; // violet Twitch
        [header addSubview:star];

        // Label "Favoris" violet Twitch
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(31, 5, 200, 18)];
        lbl.text      = @"Favoris";
        lbl.font      = [UIFont boldSystemFontOfSize:11];
        lbl.textColor = [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]; // violet Twitch
        [header addSubview:lbl];

        // Séparateur bas
        UIView *botSep = [[UIView alloc] initWithFrame:CGRectMake(8, 27.5, cv.bounds.size.width - 16, 0.5)];
        botSep.backgroundColor = sepColor;
        [header addSubview:botSep];

    } else if (indexPath.section == 1 && self.emotePickerFavoriteEmotes.count > 0) {
        // Séparateur entre favoris et toutes les emotes
        UIView *topSep = [[UIView alloc] initWithFrame:CGRectMake(8, 0, cv.bounds.size.width - 16, 0.5)];
        topSep.backgroundColor = sepColor;
        [header addSubview:topSep];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 4, 200, 20)];
        lbl.text      = @"Toutes les emotes";
        lbl.font      = [UIFont boldSystemFontOfSize:11];
        lbl.textColor = textColor;
        [header addSubview:lbl];

        UIView *botSep = [[UIView alloc] initWithFrame:CGRectMake(8, 27.5, cv.bounds.size.width - 16, 0.5)];
        botSep.backgroundColor = sepColor;
        [header addSubview:botSep];
    }
    // Section 1 sans favoris = pas de header visible (hauteur 0 via delegate)

    return header;
}

// ── Taille dynamique des cellules selon ratio de l'emote ─────────────────

static const CGFloat kCellMaxSize = 36.0; // dimension max
static const CGFloat kCellMinSize = 22.0; // dimension min

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote || emote.width <= 0 || emote.height <= 0) {
        return CGSizeMake(kCellSize, kCellSize); // carré par défaut
    }
    CGFloat ratio = (CGFloat)emote.width / (CGFloat)emote.height;
    CGFloat w, h;
    if (ratio >= 1.0) {
        // Emote plus large que haute → fixer la largeur à kCellMaxSize
        w = MIN(kCellMaxSize, kCellMaxSize * ratio);
        h = w / ratio;
    } else {
        // Emote plus haute que large → fixer la hauteur à kCellMaxSize
        h = kCellMaxSize;
        w = h * ratio;
    }
    // Assurer une taille minimale
    w = MAX(w, kCellMinSize);
    h = MAX(h, kCellMinSize);
    // Pas de +16 : plus de label de nom
    return CGSizeMake(ceil(w), ceil(h));
}

// ── Hauteur des headers (0 si inutile) ────────────────────────────────────

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
referenceSizeForHeaderInSection:(NSInteger)section {
    if (section == 0) {
        // Toujours visible même si vide (pour guider l'utilisateur)
        return self.emotePickerFavoriteEmotes.count > 0 ? CGSizeMake(cv.bounds.size.width, 28) : CGSizeZero;
    }
    // Section 1 : header "Toutes les emotes" seulement si favoris non vides
    return self.emotePickerFavoriteEmotes.count > 0 ? CGSizeMake(cv.bounds.size.width, 28) : CGSizeZero;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:kEmoteCellID
                                                                forIndexPath:indexPath];

    // Transparent — le fond du cv (sepColor) crée les mini bordures
    cell.backgroundColor = [UIColor colorWithRed:0.13 green:0.13 blue:0.15 alpha:1.0];
    cell.layer.cornerRadius = 0;
    cell.clipsToBounds = YES;

    // Nettoyer la cellule recyclée
    for (UIView *sub in cell.contentView.subviews) [sub removeFromSuperview];

    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return cell;

    // Taille réelle de la cellule
    CGSize cs = cell.bounds.size;
    if (cs.width < 1) cs = CGSizeMake(kCellSize, kCellSize);

    // Image remplit toute la cellule (avec un tout petit inset)
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(1, 1, cs.width - 2, cs.height - 2)];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    [cell.contentView addSubview:iv];

    // Étoile favoris (section 0) : petite étoile violette discrète
    if (indexPath.section == 0) {
        UIImageView *star = [[UIImageView alloc] initWithFrame:CGRectMake(cs.width - 9, 1, 8, 8)];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:6 weight:UIImageSymbolWeightMedium];
        star.image = [UIImage systemImageNamed:@"star.fill" withConfiguration:cfg];
        star.tintColor = [[UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]
                          colorWithAlphaComponent:0.7];
        [cell.contentView addSubview:star];
    }

    // Charger l'image STATIQUEMENT (pas d'animation dans le picker → pas de lag)
    NSURL *emoteURL = [self cdnURLForEmote:emote];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.URLCache = [NSURLCache sharedURLCache];
    NSURLSession *sess = [NSURLSession sessionWithConfiguration:cfg];

    [[sess dataTaskWithURL:emoteURL completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data) return;

        // Décoder en IMAGE STATIQUE seulement (frame 0 si GIF/WebP animé)
        UIImage *img = nil;
        CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (src) {
            // Toujours prendre uniquement la frame 0 → pas d'animation
            CGImageRef cgImg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
            if (cgImg) {
                img = [UIImage imageWithCGImage:cgImg];
                CGImageRelease(cgImg);
            }
            CFRelease(src);
        }
        if (!img) img = [UIImage imageWithData:data]; // fallback

        dispatch_async(dispatch_get_main_queue(), ^{
            NSIndexPath *currentPath = [cv indexPathForCell:cell];
            if (!currentPath || currentPath.item == (NSInteger)indexPath.item) {
                iv.image = img;
            }
        });
    }] resume];

    return cell;
}

// ── UICollectionViewDelegate ───────────────────────────────────────────────

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    SevenTVEmote *emote = [self _emoteForIndexPath:indexPath];
    if (!emote) return;

    // Insérer l'emote dans le champ texte SANS ouvrir le clavier.
    // On manipule directement la propriété .text puis on envoie la
    // notification de changement pour que Twitch (SwiftUI) détecte la modif.
    UIView *inputRoot = self.emotePickerTextField;
    if (inputRoot) {
        // BFS illimité : UITextView en priorité, UITextField en fallback
        __block UIView *textInput = nil;
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:inputRoot];
        while (queue.count > 0) {
            UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
            if ([v isKindOfClass:[UITextView class]]) { textInput = v; break; }
            if ([v isKindOfClass:[UITextField class]] && !textInput) textInput = v;
            for (UIView *sub in v.subviews) [queue addObject:sub];
        }

        if (textInput) {
            // Lire le texte actuel
            NSString *currentText = @"";
            if ([textInput isKindOfClass:[UITextView class]])
                currentText = ((UITextView *)textInput).text ?: @"";
            else
                currentText = ((UITextField *)textInput).text ?: @"";

            // Ajouter un espace séparateur si nécessaire
            NSString *prefix = (currentText.length > 0 && ![currentText hasSuffix:@" "]) ? @" " : @"";
            NSString *newText = [NSString stringWithFormat:@"%@%@%@ ", currentText, prefix, emote.emoteName];

            // Écrire directement sans becomeFirstResponder (pas d'ouverture clavier)
            if ([textInput isKindOfClass:[UITextView class]]) {
                UITextView *tv = (UITextView *)textInput;
                tv.text = newText;
                // Curseur en fin de texte
                tv.selectedRange = NSMakeRange(newText.length, 0);
                // Notifier Twitch du changement (SwiftUI binding)
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:UITextViewTextDidChangeNotification
                                  object:tv];
                // Aussi tenter le delegate au cas où Twitch l'écoute
                if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)])
                    [tv.delegate textViewDidChange:tv];
            } else if ([textInput isKindOfClass:[UITextField class]]) {
                UITextField *tf = (UITextField *)textInput;
                tf.text = newText;
                // Notifier Twitch du changement
                [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:UITextFieldTextDidChangeNotification
                                  object:tf];
            }
            [self log:@"\u2328\ufe0f Emote insérée : \u00ab%@\u00bb dans %@",
             emote.emoteName, NSStringFromClass([textInput class])];
        } else {
            [self log:@"\u26a0\ufe0f didSelect: aucun champ texte trouvé dans ChatInputView"];
        }
    }

    // Feedback haptique léger
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];

    // NE PAS fermer le picker → l'utilisateur peut insérer plusieurs emotes
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
