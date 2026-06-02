/*
 * SevenTVURLProtocol.m
 *
 * HOW IT WORKS:
 * Twitch charge les images d'emotes depuis:
 *   https://static-cdn.jtvnw.net/emoticons/v2/{emoteID}/default/dark/3.0
 *
 * Nous avons injecté de faux IDs préfixés "7tv_{realID}" dans les messages IRC.
 * Quand Twitch essaie de charger l'image pour "7tv_63071bb9464de28875c52531",
 * cette classe intercepte la requête et la redirige vers:
 *   https://cdn.7tv.app/emote/63071bb9464de28875c52531/4x.webp
 *
 * Résultat: Twitch affiche l'image 7TV dans son UI native, sans rien changer
 * au moteur de rendu du chat.
 */

#import "SevenTVURLProtocol.h"
#import "SevenTVManager.h"

static NSString *const kSevenTVEmoteIDPrefix = @"7tv_";
static NSString *const kHandledKey = @"SevenTVURLProtocolHandled";

@interface SevenTVURLProtocol ()
@property (nonatomic, strong) NSURLSessionDataTask *activeTask;
@end


@implementation SevenTVURLProtocol

// ============================================================
// Décide si cette classe doit gérer la requête
// On gère UNIQUEMENT les URLs qui contiennent notre préfixe "7tv_"
// ============================================================
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // Éviter les boucles infinies (ne pas traiter les requêtes qu'on a déjà modifiées)
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request]) {
        return NO;
    }

    NSString *urlString = request.URL.absoluteString ?: @"";

    // On cherche notre préfixe dans l'URL (dans le chemin de l'emote ID)
    return [urlString containsString:kSevenTVEmoteIDPrefix];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [super requestIsCacheEquivalent:a toRequest:b];
}

// ============================================================
// Traitement de la requête - on redirige vers 7TV CDN
// ============================================================
- (void)startLoading {
    NSString *urlString = self.request.URL.absoluteString;

    // Extraire l'emote ID depuis notre faux ID
    // Exemple d'URL: https://static-cdn.jtvnw.net/emoticons/v2/7tv_63071bb9464de28875c52531/default/dark/3.0
    // On cherche "7tv_" et on prend ce qui suit jusqu'au prochain "/"
    NSRange prefixRange = [urlString rangeOfString:kSevenTVEmoteIDPrefix];
    if (prefixRange.location == NSNotFound) {
        [self.client URLProtocol:self
                didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorBadURL
                                                 userInfo:nil]];
        return;
    }

    NSString *afterPrefix = [urlString substringFromIndex:prefixRange.location + kSevenTVEmoteIDPrefix.length];
    // L'ID 7TV est jusqu'au prochain "/" ou à la fin de la chaîne
    NSArray *parts  = [afterPrefix componentsSeparatedByString:@"/"];
    NSString *emoteID = parts.firstObject;

    if (!emoteID || emoteID.length == 0) {
        [self.client URLProtocol:self
                didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorBadURL
                                                 userInfo:nil]];
        return;
    }

    // ── Session CDN partagée (statique) ─────────────────────────────────────────
    // UNE seule session pour toutes les requêtes CDN → le cache HTTP NSURLCache
    // persiste entre les appels, donc une emote déjà chargée est servie
    // instantanément depuis le disque sans aucune requête réseau.
    static NSURLSession *s_cdnSession = nil;
    static dispatch_once_t s_cdnSessionOnce;
    dispatch_once(&s_cdnSessionOnce, ^{
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration defaultSessionConfiguration];

        // Cache disque dédié de 200 MB pour les images d'emotes
        NSURLCache *emoteCache = [[NSURLCache alloc]
            initWithMemoryCapacity:  30 * 1024 * 1024   // 30 MB RAM
                      diskCapacity: 200 * 1024 * 1024   // 200 MB disque
                          diskPath: @"s7tv_cdn_cache"];
        cfg.URLCache = emoteCache;
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;

        s_cdnSession = [NSURLSession sessionWithConfiguration:cfg];
    });

    // ── Construire l'URL 7TV CDN ─────────────────────────────────────────────
    // - Emote animée + animations activées → GIF
    //   (UIKit supporte GIF via UIImage.animationImages; WebP animé pas supporté
    //    nativement par la plupart des libs iOS sans flag de compilation spécial)
    // - Emote statique ou animations désactivées → WebP (plus léger)
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    // Chercher si l'emote est animée — lecture thread-safe via emoteQueue
    __block BOOL isAnimated = NO;
    dispatch_sync(mgr.emoteQueue, ^{
        SevenTVEmote *found = mgr.channelEmotes[emoteID] ?: mgr.globalEmotes[emoteID];
        if (!found) {
            // Fallback: chercher par emoteID dans les valeurs
            for (SevenTVEmote *e in mgr.channelEmotes.allValues) {
                if ([e.emoteID isEqualToString:emoteID]) { found = e; break; }
            }
        }
        if (!found) {
            for (SevenTVEmote *e in mgr.globalEmotes.allValues) {
                if ([e.emoteID isEqualToString:emoteID]) { found = e; break; }
            }
        }
        isAnimated = found ? found.isAnimated : NO;
    });

    BOOL useGif = isAnimated && mgr.showAnimated;
    NSString *extension = useGif ? @"4x.gif" : @"4x.webp";

    NSString *cdnURL = [NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/%@",
                        emoteID, extension];

    [mgr log:@"🌐 URLProtocol intercept → emote:%@ animé:%@ url:%@",
     emoteID, isAnimated ? @"oui" : @"non", cdnURL];

    NSURL *targetURL = [NSURL URLWithString:cdnURL];
    if (!targetURL) {
        [self.client URLProtocol:self
                didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorBadURL
                                                 userInfo:nil]];
        return;
    }

    // Créer une nouvelle requête vers 7TV (marquée pour éviter les boucles)
    NSMutableURLRequest *newRequest = [NSMutableURLRequest requestWithURL:targetURL];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:newRequest];
    newRequest.cachePolicy = NSURLRequestReturnCacheDataElseLoad;

    // Utiliser la session statique partagée (cache persistant)
    NSURLSession *session = s_cdnSession;

    __weak typeof(self) weakSelf = self;
    self.activeTask = [session dataTaskWithRequest:newRequest
                               completionHandler:^(NSData *data,
                                                    NSURLResponse *response,
                                                    NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            [strongSelf.client URLProtocol:strongSelf didFailWithError:error];
            return;
        }

        if (data && response) {
            // Créer une fausse réponse avec l'URL originale (celle que Twitch attendait)
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            NSString *contentType = useGif ? @"image/gif" : @"image/webp";
            NSHTTPURLResponse *spoofedResponse = [[NSHTTPURLResponse alloc]
                initWithURL:strongSelf.request.URL
                statusCode:httpResponse.statusCode
               HTTPVersion:@"HTTP/1.1"
              headerFields:@{@"Content-Type": contentType}];

            [strongSelf.client URLProtocol:strongSelf
                        didReceiveResponse:spoofedResponse
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

@end
