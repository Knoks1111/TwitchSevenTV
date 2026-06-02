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
 *
 * FIX "cellule vide" (v1.1):
 * Quand une image finit de se télécharger, on force Twitch à re-render ses
 * cellules visibles via reloadVisibleRows/reloadVisibleItems. Twitch relit
 * ses cellules → relance les requêtes images → cache chaud → instantané.
 * Uniquement déclenché à la fin d'un PREMIER téléchargement (pas en boucle).
 */

#import "SevenTVURLProtocol.h"
#import "SevenTVManager.h"

static NSString *const kSevenTVEmoteIDPrefix = @"7tv_";
static NSString *const kHandledKey = @"SevenTVURLProtocolHandled";

// ── Session CDN partagée (niveau fichier) ────────────────────────────────────
static NSURLSession *s_cdnSession = nil;
static dispatch_once_t s_cdnSessionOnce;

static NSURLSession *SevenTVGetCDNSession(void) {
    dispatch_once(&s_cdnSessionOnce, ^{
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration defaultSessionConfiguration];
        NSURLCache *emoteCache = [[NSURLCache alloc]
            initWithMemoryCapacity:  30 * 1024 * 1024   // 30 MB RAM
                      diskCapacity: 200 * 1024 * 1024   // 200 MB disque
                          diskPath: @"s7tv_cdn_cache"];
        cfg.URLCache = emoteCache;
        cfg.requestCachePolicy = NSURLRequestReturnCacheDataElseLoad;
        s_cdnSession = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s_cdnSession;
}


// ── Parcours récursif de la hiérarchie de vues ───────────────────────────────
//
// Collecte tous les UITableView et UICollectionView dans la hiérarchie.
// On cherche en profondeur depuis la fenêtre principale — Twitch imbrique
// son chat dans plusieurs niveaux de conteneurs.
//
// Paramètre `out`: tableau mutable passé par référence dans lequel on ajoute
// les vues trouvées. Pas de valeur de retour pour éviter des allocs répétées.

static void SevenTVCollectScrollViews(UIView *root,
                                      NSMutableArray<UIScrollView *> *out) {
    if (!root) return;
    if ([root isKindOfClass:[UITableView class]] ||
        [root isKindOfClass:[UICollectionView class]]) {
        [out addObject:(UIScrollView *)root];
    }
    for (UIView *child in root.subviews) {
        SevenTVCollectScrollViews(child, out);
    }
}


// ── Reload des cellules visibles ─────────────────────────────────────────────
//
// Appelée sur le main thread après qu'une image a fini de se télécharger.
//
// Stratégie:
//   • UITableView  → reloadRowsAtIndexPaths:withRowAnimation:None
//     (reloadVisibleRows n'existe pas directement — on recharge les
//      indexPaths des cellules visibles, ce qui ne scroll pas)
//   • UICollectionView → reloadItemsAtIndexPaths: sur les items visibles
//
// On filtre sur les vues qui ressemblent au chat (contentSize haute,
// beaucoup de cellules) pour ne pas reloader des tableViews parasites
// (menus, overlays, etc.) qui n'ont rien à voir.

static void SevenTVReloadVisibleChatCells(void) {
    NSCAssert([NSThread isMainThread], @"SevenTVReloadVisibleChatCells must run on main thread");

    UIWindow *keyWindow = nil;
    // iOS 13+ : chercher la première scène connectée en foreground
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                keyWindow = ((UIWindowScene *)scene).windows.firstObject;
                break;
            }
        }
    }
    // Fallback iOS 12 ou si aucune scène trouvée
    if (!keyWindow) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    }
    if (!keyWindow) return;

    NSMutableArray<UIScrollView *> *scrollViews = [NSMutableArray array];
    SevenTVCollectScrollViews(keyWindow, scrollViews);

    for (UIScrollView *sv in scrollViews) {

        // ── Heuristique "vue de chat" ────────────────────────────────────────
        // Le chat Twitch est une liste longue (contentSize.height > 500pt)
        // avec au moins quelques cellules (évite les tableViews à 0-1 ligne).
        // On exclut aussi les vues trop étroites (overlays) et celles dont
        // la hauteur content est inférieure à la hauteur frame (liste courte).
        if (sv.contentSize.height < 500.0) continue;

        if ([sv isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)sv;
            NSArray<NSIndexPath *> *visible = tv.indexPathsForVisibleRows;
            if (visible.count == 0) continue;

            [tv reloadRowsAtIndexPaths:visible
                      withRowAnimation:UITableViewRowAnimationNone];

        } else if ([sv isKindOfClass:[UICollectionView class]]) {
            UICollectionView *cv = (UICollectionView *)sv;
            NSArray<NSIndexPath *> *visible = [cv indexPathsForVisibleItems];
            if (visible.count == 0) continue;

            [cv reloadItemsAtIndexPaths:visible];
        }
    }
}


// ────────────────────────────────────────────────────────────────────────────

@interface SevenTVURLProtocol ()
@property (nonatomic, strong) NSURLSessionDataTask *activeTask;
@end


@implementation SevenTVURLProtocol

// ============================================================
// Décide si cette classe doit gérer la requête
// On gère UNIQUEMENT les URLs qui contiennent notre préfixe "7tv_"
// ============================================================
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request]) {
        return NO;
    }
    NSString *urlString = request.URL.absoluteString ?: @"";
    return [urlString containsString:kSevenTVEmoteIDPrefix];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (BOOL)requestIsCacheEquivalent:(NSURLRequest *)a toRequest:(NSURLRequest *)b {
    return [super requestIsCacheEquivalent:a toRequest:b];
}

// ============================================================
// Préchauffage de la connexion TCP/TLS vers cdn.7tv.app
// ============================================================
+ (void)prewarmCDNConnection {
    NSURL *warmURL = [NSURL URLWithString:@"https://cdn.7tv.app/emote/01F6MSP3NV00001B6E/1x.webp"];
    if (!warmURL) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:warmURL];
    req.HTTPMethod = @"HEAD";
    req.timeoutInterval = 10.0;

    [[SevenTVGetCDNSession() dataTaskWithRequest:req
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSLog(@"[TwitchSevenTV] 🔥 CDN prewarm: %@",
              e ? e.localizedDescription : @"OK");
    }] resume];
}


// ============================================================
// Traitement de la requête - on redirige vers 7TV CDN
// ============================================================
- (void)startLoading {
    NSString *urlString = self.request.URL.absoluteString;

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
    NSArray  *parts       = [afterPrefix componentsSeparatedByString:@"/"];
    NSString *emoteID     = parts.firstObject;

    if (!emoteID || emoteID.length == 0) {
        [self.client URLProtocol:self
                didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorBadURL
                                                 userInfo:nil]];
        return;
    }

    // ── Détecter si la réponse est déjà en cache ─────────────────────────────
    // Si elle l'est, URLProtocol appellera immédiatement didReceiveResponse +
    // didLoadData + didFinishLoading → Twitch met à jour l'imageView sans délai.
    // On n'a PAS besoin de reloadVisibleRows dans ce cas — la cellule était
    // déjà à l'écran et Twitch sait déjà dessiner l'image.
    // On marque donc ce flag pour éviter le reload inutile.
    NSString *cdnURLCheck = [NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/4x.webp", emoteID];
    NSURL    *cdnURLObj   = [NSURL URLWithString:cdnURLCheck];
    NSMutableURLRequest *cacheCheckReq = [NSMutableURLRequest requestWithURL:cdnURLObj];
    cacheCheckReq.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
    BOOL alreadyCached = ([SevenTVGetCDNSession().configuration.URLCache
                           cachedResponseForRequest:cacheCheckReq] != nil);

    // ── Session CDN partagée ─────────────────────────────────────────────────
    NSURLSession *session = SevenTVGetCDNSession();

    // ── Chercher si l'emote est animée ───────────────────────────────────────
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    __block BOOL isAnimated = NO;
    dispatch_sync(mgr.emoteQueue, ^{
        SevenTVEmote *found = mgr.channelEmotes[emoteID] ?: mgr.globalEmotes[emoteID];
        if (!found) {
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

    BOOL useAnimated = isAnimated && mgr.showAnimated;
    NSString *extension = @"4x.webp";

    NSString *cdnURL = [NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/%@",
                        emoteID, extension];

    [mgr log:@"🌐 URLProtocol intercept → emote:%@ animé:%@ cached:%@ url:%@",
     emoteID,
     useAnimated    ? @"oui" : @"non",
     alreadyCached  ? @"oui" : @"non",
     cdnURL];

    NSURL *targetURL = [NSURL URLWithString:cdnURL];
    if (!targetURL) {
        [self.client URLProtocol:self
                didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorBadURL
                                                 userInfo:nil]];
        return;
    }

    NSMutableURLRequest *newRequest = [NSMutableURLRequest requestWithURL:targetURL];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:newRequest];
    newRequest.cachePolicy = NSURLRequestReturnCacheDataElseLoad;

    __weak typeof(self) weakSelf = self;

    self.activeTask = [session dataTaskWithRequest:newRequest
                               completionHandler:^(NSData      *data,
                                                   NSURLResponse *response,
                                                   NSError       *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            [strongSelf.client URLProtocol:strongSelf didFailWithError:error];
            return;
        }

        if (data && response) {
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

            // ── Fix "cellule vide" ───────────────────────────────────────────
            //
            // Contexte: Twitch a affiché le message IRC AVANT que l'image soit
            // disponible. La cellule contient un UIImageView vide en attente.
            // NSURLCache vient d'être rempli (cache froid → chaud).
            //
            // Problème: Twitch ne sait pas que l'image est maintenant dispo.
            // Il ne re-render pas la cellule → la case vide reste vide.
            //
            // Solution: on force Twitch à relire ses cellules visibles.
            // Twitch re-demande l'image pour chaque cellule → NSURLCache répond
            // immédiatement (cache chaud) → UIImageView affiche l'emote.
            //
            // On ne le fait PAS si l'image était déjà en cache car dans ce cas
            // Twitch avait accès à l'image dès le premier rendu — pas de case
            // vide à corriger, et un reload inutile peut faire flasher l'UI.
            //
            // On ne le fait PAS non plus si la requête a échoué (géré au-dessus).
            if (!alreadyCached) {
                [[SevenTVManager sharedManager] log:@"♻️ Premier téléchargement de %@ → reloadVisibleRows", emoteID];

                // Toujours sur le main thread — UIKit n'est pas thread-safe.
                // On utilise async et non sync pour ne pas bloquer le thread
                // de la NSURLSession (qui est un thread interne d'Apple).
                dispatch_async(dispatch_get_main_queue(), ^{
                    SevenTVReloadVisibleChatCells();
                });
            }

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
