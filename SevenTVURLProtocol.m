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
 */

#import "SevenTVURLProtocol.h"
#import "SevenTVManager.h"

static NSString *const kSevenTVEmoteIDPrefix = @"7tv_";
static NSString *const kHandledKey           = @"SevenTVURLProtocolHandled";

// ── Session CDN partagée ─────────────────────────────────────────────────────
// Une seule session = cache HTTP NSURLCache persistant entre appels.
static NSURLSession    *s_cdnSession     = nil;
static dispatch_once_t  s_cdnSessionOnce;

static NSURLSession *SevenTVGetCDNSession(void) {
    dispatch_once(&s_cdnSessionOnce, ^{
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration defaultSessionConfiguration];
        NSURLCache *emoteCache = [[NSURLCache alloc]
            initWithMemoryCapacity:  30 * 1024 * 1024   // 30 MB RAM
                      diskCapacity: 200 * 1024 * 1024   // 200 MB disque
                          diskPath: @"s7tv_cdn_cache"];
        cfg.URLCache              = emoteCache;
        cfg.requestCachePolicy    = NSURLRequestReturnCacheDataElseLoad;
        s_cdnSession = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s_cdnSession;
}

// ── URL CDN pour un emote ID ─────────────────────────────────────────────────
static NSURL *SevenTVCDNURLForEmoteID(NSString *emoteID) {
    NSString *str = [NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/4x.webp", emoteID];
    return [NSURL URLWithString:str];
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
    [mgr log:@"🌐 URLProtocol intercept → emote:%@", emoteID];

    NSMutableURLRequest *newRequest = [NSMutableURLRequest requestWithURL:targetURL];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:newRequest];
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
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSHTTPURLResponse *spoofed = [[NSHTTPURLResponse alloc]
                initWithURL:strongSelf.request.URL
                statusCode:http.statusCode
               HTTPVersion:@"HTTP/1.1"
              headerFields:@{@"Content-Type": @"image/webp"}];

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

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    return ([SevenTVGetCDNSession().configuration.URLCache
             cachedResponseForRequest:req] != nil);
}

// Télécharge l'image et appelle completion quand elle est en cache.
// completion est toujours appelé (succès, erreur, ou timeout 1s).
// Utilise la même session CDN que URLProtocol → même cache partagé.
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

    NSURLSession *session = SevenTVGetCDNSession();

    // Si déjà en cache → completion immédiate, pas de réseau
    NSMutableURLRequest *checkReq = [NSMutableURLRequest requestWithURL:url];
    checkReq.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    if ([session.configuration.URLCache cachedResponseForRequest:checkReq]) {
        if (completion) completion();
        return;
    }

    // File série pour garantir que completion est appelé exactement une fois,
    // peu importe lequel (timeout ou téléchargement) arrive en premier.
    __block BOOL done = NO;
    dispatch_queue_t onceQ = dispatch_queue_create("s7tv.prefetch.once", DISPATCH_QUEUE_SERIAL);

    void (^finish)(NSString *reason) = ^(NSString *reason) {
        dispatch_async(onceQ, ^{
            if (!done) {
                done = YES;
                [[SevenTVManager sharedManager] log:@"📦 Préfetch %@ → %@", emoteID, reason];
                if (completion) completion();
            }
        });
    };

    // Timeout de sécurité : 1s max pour ne pas bloquer le chat indéfiniment
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        finish(@"timeout 1s");
    });

    // Téléchargement direct via la session CDN (kHandledKey évite la boucle URLProtocol)
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:req];
    req.cachePolicy = NSURLRequestReturnCacheDataElseLoad;

    [[session dataTaskWithRequest:req
               completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        finish(err ? err.localizedDescription : @"OK");
    }] resume];
}


// ============================================================
// MARK: - Préchauffage connexion CDN
// ============================================================

+ (void)prewarmCDNConnection {
    NSURL *warmURL = [NSURL URLWithString:@"https://cdn.7tv.app/emote/01F6MSP3NV00001B6E/1x.webp"];
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
