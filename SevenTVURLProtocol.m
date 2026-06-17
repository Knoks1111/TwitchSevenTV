/*
 * SevenTVURLProtocol.m
 *
 * HOW IT WORKS:
 * Twitch charge les images d'emotes depuis:
 *   https://static-cdn.jtvnw.net/emoticons/v2/{emoteID}/default/dark/3.0
 *
 * On injecte de faux IDs préfixés "7tv_{realID}" dans les messages IRC.
 * Quand Twitch essaie de charger l'image pour "7tv_63071bb9464de28875c52531",
 * cette classe intercepte la requête et la redirige vers:
 *   https://cdn.7tv.app/emote/63071bb9464de28875c52531/4x.webp
 *
 * FIX "cellule vide" (v1.2):
 * Le message IRC est retenu dans TweakSevenTV.m jusqu'à ce que toutes ses
 * emotes soient dans le cache (via prefetchEmoteID:completion:).
 * Twitch reçoit le message APRÈS que les images sont prêtes → plus jamais
 * de case vide, même à la première occurrence d'une emote.
 *
 * FIX "cellule vide" (v1.3) — réponse synchrone sur cache hit:
 * Même avec le prefetch v1.2, startLoading passait TOUJOURS par un dataTask
 * asynchrone. Le callback arrivait sur un thread background APRÈS que CoreText
 * avait déjà calculé le layout du message → attachment vide → layout figé.
 * Workaround utilisateur : scroller manuellement pour forcer un re-render UIKit.
 *
 * Le fix : dans startLoading, interroger NSURLCache de façon SYNCHRONE avant
 * de lancer le dataTask. Si l'image est en cache → répondre immédiatement,
 * dans le même call stack → CoreText a l'image pendant le calcul → jamais
 * de case vide, même sans le workaround scroll.
 */

#import "SevenTVURLProtocol.h"
#import "SevenTVManager.h"

static NSString *const kSevenTVEmoteIDPrefix = @"7tv_";
static NSString *const kHandledKey           = @"SevenTVURLProtocolHandled";

// ── Sessions CDN ──────────────────────────────────────────────────────────────
//
// ARCHITECTURE (important pour la cohérence du cache) :
//
//   SevenTVGetCDNSession()      — utilisée par URLProtocol/startLoading et prewarm
//   SevenTVGetPrefetchSession() — utilisée par prefetchEmoteID:completion:
//
// Les deux partagent le MÊME objet NSURLCache (s_emoteCache).
// Les deux ont protocolClasses = @[] → SevenTVURLProtocol n'est jamais
// dans leur liste de protocoles → aucune boucle d'interception possible →
// aucun besoin de mettre kHandledKey sur les requêtes CDN →
// les requêtes arrivent au cache avec la clé URL brute (identique dans les deux).
//
// Avant ce correctif, kHandledKey était appliqué sur les NSMutableURLRequest
// via [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:req].
// Cette propriété passe par CFURLRequestSetProtocolProperty et est prise en
// compte dans le calcul de la clé NSURLCache. Résultat : le prefetch stockait
// sous (URL + kHandledKey=YES) mais isEmoteIDCached vérifiait sous (URL seul) →
// miss systématique à chaque première occurrence d'une emote.

static NSURLCache      *s_emoteCache     = nil;
static dispatch_once_t  s_emoteCacheOnce;

// Cache partagé entre les deux sessions.
static NSURLCache *SevenTVGetSharedCache(void) {
    dispatch_once(&s_emoteCacheOnce, ^{
        s_emoteCache = [[NSURLCache alloc]
            initWithMemoryCapacity:  30 * 1024 * 1024   // 30 MB RAM
                      diskCapacity: 200 * 1024 * 1024   // 200 MB disque
                          diskPath: @"s7tv_cdn_cache"];
    });
    return s_emoteCache;
}

static NSURLSession    *s_cdnSession     = nil;
static dispatch_once_t  s_cdnSessionOnce;

static NSURLSession *SevenTVGetCDNSession(void) {
    dispatch_once(&s_cdnSessionOnce, ^{
        // ephemeralSessionConfiguration : configuration VIERGE, sans héritage
        // du sharedURLCache ni des hooks de TwitchControl (setRequestCachePolicy:,
        // removeAllCachedResponses). defaultSessionConfiguration hérite du
        // sharedURLCache que TwitchControl vide périodiquement → cache miss
        // systématique sur toutes les emotes → re-téléchargement à chaque fois.
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache           = SevenTVGetSharedCache(); // notre cache isolé
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        cfg.protocolClasses    = @[]; // pas de boucle d'interception
        s_cdnSession = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s_cdnSession;
}

// Session dédiée au prefetch — même cache, même isolation URLProtocol.
static NSURLSession    *s_prefetchSession     = nil;
static dispatch_once_t  s_prefetchSessionOnce;

static NSURLSession *SevenTVGetPrefetchSession(void) {
    dispatch_once(&s_prefetchSessionOnce, ^{
        // Même raison qu'au-dessus : ephemeral isole du sharedURLCache
        // et des hooks TwitchControl. Même cache partagé s_emoteCache.
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache           = SevenTVGetSharedCache();
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        cfg.protocolClasses    = @[];
        // 4 connexions max pour le bulk — laisse de la place à l'urgent session
        cfg.HTTPMaximumConnectionsPerHost = 4;
        s_prefetchSession = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s_prefetchSession;
}

// Session urgente — utilisée UNIQUEMENT par prefetchEmoteID:completion:
// (déclenché quand une emote apparaît dans le chat).
// Complètement séparée de la bulk session → pas de contention HTTP/2.
// Même NSURLCache partagé → les deux écrivent au même endroit.
static NSURLSession    *s_urgentSession     = nil;
static dispatch_once_t  s_urgentSessionOnce;

static NSURLSession *SevenTVGetUrgentSession(void) {
    dispatch_once(&s_urgentSessionOnce, ^{
        // Même raison : ephemeral pour isolation totale.
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache           = SevenTVGetSharedCache(); // même cache que bulk
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        cfg.protocolClasses    = @[];
        // 8 connexions — couvre le semaphore bulk (6) + les urgences temps réel.
        // HTTP/2 multiplex sur une connexion TCP, donc pas de surcoût réseau.
        cfg.HTTPMaximumConnectionsPerHost = 8;
        s_urgentSession = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s_urgentSession;
}

// ── URL CDN pour un emote ID ─────────────────────────────────────────────────
// 4x.gif : 1x.gif retiré — logs confirmés montrent un 404 quasi systématique
// sur cette résolution (CDN 7TV n'a presque jamais de variante 1x). 4x.gif est
// la résolution déjà confirmée disponible et fonctionnelle pour l'animation.
static NSURL *SevenTVCDNURLForEmoteID(NSString *emoteID) {
    NSString *str = [NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/4x.gif", emoteID];
    return [NSURL URLWithString:str];
}

// ── Validation réponse CDN ───────────────────────────────────────────────────
//
// PROBLÈME CORRIGÉ : ni startLoading (cache miss) ni prefetchEmoteID:completion:
// ne vérifiaient le statut HTTP ni le contenu réel des données avant de les
// mettre en cache et de les transmettre à Twitch avec un Content-Type:image/gif
// spoofé. Si le CDN renvoie un 404 (ex: emote sans variante 1x disponible) avec
// un petit corps JSON/HTML d'erreur, ce corps était accepté comme "image valide",
// stocké en cache tel quel, et servi à Twitch qui échoue à le décoder → carré
// vide PERMANENT (le mauvais contenu reste en cache pour toujours, le scroll ne
// corrige rien puisque ce n'est pas un problème de timing).
//
// Double vérification :
//   - statusCode == 200 — élimine 404/403/5xx etc.
//   - signature de fichier GIF ("GIF8" en tête) — élimine tout corps de
//     réponse qui ne serait pas un vrai GIF (page d'erreur, JSON, HTML),
//     même si le CDN renvoyait par erreur un statusCode 200 sur une erreur.
static BOOL SevenTVIsValidGIFResponse(NSURLResponse *response, NSData *data) {
    if (!data || data.length < 6) return NO;

    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
        if (status != 200) return NO;
    }

    static const char gifMagic[4] = {'G', 'I', 'F', '8'};
    const char *bytes = (const char *)data.bytes;
    return (memcmp(bytes, gifMagic, sizeof(gifMagic)) == 0);
}


@interface SevenTVURLProtocol ()
@property (nonatomic, strong) NSURLSessionDataTask *activeTask;
@end


@implementation SevenTVURLProtocol

// ============================================================
// MARK: - NSURLProtocol — interception des requêtes Twitch
// ============================================================

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // Éviter les boucles infinies
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request]) return NO;
    NSString *url = request.URL.absoluteString ?: @"";
    return [url containsString:kSevenTVEmoteIDPrefix];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [super requestIsCacheEquivalent:a toRequest:b];
}

- (void)startLoading {
    NSString *urlString = self.request.URL.absoluteString;

    // Extraire l'emote ID depuis l'URL Twitch (ex: .../7tv_63071bb9.../default/...)
    NSRange prefixRange = [urlString rangeOfString:kSevenTVEmoteIDPrefix];
    if (prefixRange.location == NSNotFound) {
        [self.client URLProtocol:self
                didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorBadURL
                                                 userInfo:nil]];
        return;
    }

    NSString *afterPrefix = [urlString substringFromIndex:prefixRange.location
                                                         + kSevenTVEmoteIDPrefix.length];
    NSString *emoteID = [afterPrefix componentsSeparatedByString:@"/"].firstObject;

    if (!emoteID.length) {
        [self.client URLProtocol:self
                didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorBadURL
                                                 userInfo:nil]];
        return;
    }

    // Construire l'URL CDN 7TV
    NSURL *targetURL = SevenTVCDNURLForEmoteID(emoteID);
    if (!targetURL) {
        [self.client URLProtocol:self
                didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorBadURL
                                                 userInfo:nil]];
        return;
    }

    SevenTVManager *mgr = [SevenTVManager sharedManager];

    // ── v1.3 FIX: vérification synchrone du cache ─────────────────────────────
    // NSURLCache.cachedResponseForRequest: est synchrone et thread-safe.
    // Si l'image est en cache (grâce au prefetch v1.2), on répond IMMÉDIATEMENT
    // dans le même call stack → CoreText a l'image pendant le calcul du layout
    // → plus jamais de case vide, plus besoin du workaround scroll.
    NSMutableURLRequest *cacheCheckReq = [NSMutableURLRequest requestWithURL:targetURL];
    cacheCheckReq.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    NSCachedURLResponse *cached = [SevenTVGetSharedCache() cachedResponseForRequest:cacheCheckReq];

    if (cached) {
        [mgr log:@"⚡️ URLProtocol cache hit (sync) → emote:%@", emoteID];

        NSHTTPURLResponse *spoofed = [[NSHTTPURLResponse alloc]
            initWithURL:self.request.URL
            statusCode:200
           HTTPVersion:@"HTTP/1.1"
          headerFields:@{@"Content-Type": @"image/gif"}];

        [self.client URLProtocol:self
              didReceiveResponse:spoofed
              cacheStoragePolicy:NSURLCacheStorageAllowed];
        [self.client URLProtocol:self didLoadData:cached.data];
        [self.client URLProtocolDidFinishLoading:self];
        return; // ← on sort sans jamais créer de dataTask
    }
    // ─────────────────────────────────────────────────────────────────────────

    // Cache miss (ne devrait arriver que si le prefetch a échoué ou expiré).
    // On tombe en fallback asynchrone normal.
    [mgr log:@"🌐 URLProtocol cache miss (async) → emote:%@", emoteID];

    // Pas de kHandledKey : SevenTVGetCDNSession a protocolClasses=@[],
    // donc SevenTVURLProtocol n'intercepte jamais ses propres requêtes.
    NSMutableURLRequest *newRequest = [NSMutableURLRequest requestWithURL:targetURL];
    newRequest.cachePolicy = NSURLRequestReturnCacheDataElseLoad;

    __weak typeof(self) weakSelf = self;
    self.activeTask = [SevenTVGetCDNSession()
        dataTaskWithRequest:newRequest
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            [strongSelf.client URLProtocol:strongSelf didFailWithError:error];
            return;
        }

        if (data && response) {
            if (!SevenTVIsValidGIFResponse(response, data)) {
                NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                    ? ((NSHTTPURLResponse *)response).statusCode : -1;
                [mgr log:@"❌ Réponse CDN invalide (cache miss) → emote:%@ status:%ld bytes:%lu — non mise en cache",
                    emoteID, (long)status, (unsigned long)data.length];
                [strongSelf.client URLProtocol:strongSelf
                              didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                                  code:NSURLErrorBadServerResponse
                                                              userInfo:nil]];
                return;
            }

            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSHTTPURLResponse *spoofed = [[NSHTTPURLResponse alloc]
                initWithURL:strongSelf.request.URL
                statusCode:http.statusCode
               HTTPVersion:@"HTTP/1.1"
              headerFields:@{@"Content-Type": @"image/gif"}];

            [strongSelf.client URLProtocol:strongSelf
                        didReceiveResponse:spoofed
                        cacheStoragePolicy:NSURLCacheStorageAllowed];
            [strongSelf.client URLProtocol:strongSelf didLoadData:data];
            [strongSelf.client URLProtocolDidFinishLoading:strongSelf];
        } else {
            [strongSelf.client URLProtocol:strongSelf
                          didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                              code:NSURLErrorZeroByteResource
                                                          userInfo:nil]];
        }
    }];

    [self.activeTask resume];
}

- (void)stopLoading {
    [self.activeTask cancel];
    self.activeTask = nil;
}


// ============================================================
// MARK: - Utilitaires (appelés depuis TweakSevenTV.m)
// ============================================================

// Vérifie si l'image est en cache sans faire de réseau.
+ (BOOL)isEmoteIDCached:(NSString *)emoteID {
    if (!emoteID.length) return NO;
    NSURL *url = SevenTVCDNURLForEmoteID(emoteID);
    if (!url) return NO;

    // Requête propre (sans kHandledKey) → même clé que prefetch et URLProtocol.
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    return ([SevenTVGetSharedCache() cachedResponseForRequest:req] != nil);
}

// Télécharge l'image et appelle completion quand elle est en cache.
// completion est toujours appelé (succès, erreur, ou timeout 1s).
//
// Utilise SevenTVGetPrefetchSession() — session avec protocolClasses=@[] et
// même NSURLCache que SevenTVGetCDNSession() — pour garantir que :
//   • la requête ne boucle pas via SevenTVURLProtocol (pas besoin de kHandledKey)
//   • la réponse est stockée sous la clé URL brute
//   • URLProtocol/startLoading trouve l'entrée en cache au premier coup
+ (void)prefetchEmoteID:(NSString *)emoteID completion:(void(^)(void))completion {
    if (!emoteID.length) {
        if (completion) completion();
        return;
    }

    NSURL *url = SevenTVCDNURLForEmoteID(emoteID);
    if (!url) {
        if (completion) completion();
        return;
    }

    // Si déjà en cache → completion immédiate, pas de réseau.
    // Requête propre (sans kHandledKey) → clé identique à ce que stocke prefetch.
    NSMutableURLRequest *checkReq = [NSMutableURLRequest requestWithURL:url];
    checkReq.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    if ([SevenTVGetSharedCache() cachedResponseForRequest:checkReq]) {
        if (completion) completion();
        return;
    }

    // Téléchargement en background via la session prefetch dédiée.
    // La completion est appelée exactement une fois par NSURLSession :
    // succès, erreur réseau, ou expiration (timeoutInterval).
    // 30s : avec 6 streams HTTP/2 en parallèle et 335 emotes, les requêtes
    // en queue pouvaient expirer avant d'être envoyées avec l'ancien 10s.
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy     = NSURLRequestReturnCacheDataElseLoad;
    req.timeoutInterval = 30.0;

    // Session URGENTE — indépendante du bulk prefetch.
    [[SevenTVGetUrgentSession() dataTaskWithRequest:req
               completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            [[SevenTVManager sharedManager] log:@"⚠️ Préfetch %@ → %@",
             emoteID, err.localizedDescription];
        }
        // Stockage manuel — NSURLSession ne stocke que si le CDN retourne les
        // bons headers Cache-Control. On utilise une requête propre (juste l'URL)
        // pour que la clé de cache corresponde exactement à ce que startLoading
        // lit via cachedResponseForRequest:, évitant un cache miss à cause de
        // cachePolicy/timeoutInterval différents.
        //
        // Validation AVANT stockage : sans ça, un 404 7TV (ex: pas de variante
        // 1x pour cette emote) avec un petit corps JSON/HTML d'erreur était
        // accepté comme image valide et restait en cache pour toujours →
        // carré vide permanent que même le scroll ne corrige jamais.
        if (data && resp && !err) {
            if (SevenTVIsValidGIFResponse(resp, data)) {
                NSCachedURLResponse *toCache = [[NSCachedURLResponse alloc]
                    initWithResponse:resp data:data];
                NSURLRequest *cacheKey = [NSURLRequest requestWithURL:url];
                [SevenTVGetSharedCache() storeCachedResponse:toCache forRequest:cacheKey];
            } else {
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                    ? ((NSHTTPURLResponse *)resp).statusCode : -1;
                [[SevenTVManager sharedManager] log:
                    @"❌ Préfetch %@ → réponse invalide status:%ld bytes:%lu — non mise en cache",
                    emoteID, (long)status, (unsigned long)data.length];
            }
        }
        if (completion) completion();
    }] resume];
}


// ============================================================
// MARK: - Préchauffage connexion CDN
// ============================================================

// ============================================================
// MARK: - Cache partagé (accessible depuis SevenTVManager pour le picker)
// ============================================================

+ (NSURLCache *)sharedEmoteCache {
    return SevenTVGetSharedCache();
}

+ (void)prewarmCDNConnection {
    NSURL *warmURL = [NSURL URLWithString:@"https://cdn.7tv.app/emote/01F6MSP3NV00001B6E/4x.gif"];
    if (!warmURL) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:warmURL];
    req.HTTPMethod     = @"HEAD";
    req.timeoutInterval = 10.0;

    [[SevenTVGetCDNSession() dataTaskWithRequest:req
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSLog(@"[TwitchSevenTV] 🔥 CDN prewarm: %@",
              e ? e.localizedDescription : @"OK");
    }] resume];
}

@end
