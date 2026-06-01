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

    // Construire l'URL 7TV CDN
    // On essaie d'abord en WebP (meilleur support iOS 14+)
    // Si le streamer a désactivé les animés, on prend en static
    BOOL wantAnimated = [SevenTVManager sharedManager].showAnimated;
    NSString *extension = wantAnimated ? @"4x.webp" : @"4x.webp"; // WebP supporte les deux

    NSString *cdnURL = [NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/%@",
                        emoteID, extension];

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
    newRequest.cachePolicy = NSURLRequestReturnCacheDataElseLoad; // Cache agressif

    // Effectuer la requête vers le vrai CDN 7TV
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

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
            NSHTTPURLResponse *spoofedResponse = [[NSHTTPURLResponse alloc]
                initWithURL:strongSelf.request.URL
                statusCode:httpResponse.statusCode
               HTTPVersion:@"HTTP/1.1"
              headerFields:@{@"Content-Type": @"image/webp"}];

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
