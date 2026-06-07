/*
 * SevenTVChatCell.m
 *
 * FIX v3 — Badges :
 *   Les badges Twitch IRC (broadcaster/1, subscriber/0...) utilisent un
 *   nom symbolique, pas un UUID. L'URL publique sans auth est :
 *     https://badges.twitch.tv/v1/badges/global/display?language=en
 *   On charge ce JSON une seule fois au démarrage pour construire la map
 *   badgeName+version → imageURL, puis on télécharge les images.
 *   Pour les badges channel-specific : même endpoint avec /channels/{id}/.
 *
 *   On utilise une NSURLSession singleton (pas une nouvelle session par appel)
 *   pour éviter la fuite de sessions et la limite iOS.
 *
 * FIX v2 — Emotes :
 *   Clé de cache = URL CDN réelle (cdn.7tv.app), pas l'URL Twitch fake.
 */

#import "SevenTVChatCell.h"
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"
#import <os/lock.h>

NSString * const kSevenTVChatCellReuseID = @"SevenTVChatCell";

static const CGFloat kEmoteTargetHeight = 22.0;
static const CGFloat kBadgeTargetSize   = 18.0;


// ────────────────────────────────────────────────────────────
// MARK: - Session singleton pour les badges
// ────────────────────────────────────────────────────────────

static NSURLSession *S7TVBadgeSession(void) {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // ephemeralSessionConfiguration : isolation du sharedURLCache Twitch
        // protocolClasses non surchargé → hérite de la config Twitch swizzlée,
        // ce qui est OK car nos URLs badge ne contiennent pas "7tv_"
        // → SevenTVURLProtocol.canInitWithRequest retourne NO → pas de boucle
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 10.0;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}


// ────────────────────────────────────────────────────────────
// MARK: - Registre des URLs de badges
// badge "name/version" → URL image (ex: "broadcaster/1" → "https://...")
// Chargé une seule fois depuis l'API publique Twitch Badges
// ────────────────────────────────────────────────────────────

// Map globale : "badgeName/version" → imageURLString
static NSMutableDictionary<NSString *, NSString *> *s_badgeURLMap = nil;
// Map globale : imageURLString → UIImage (cache mémoire)
static NSMutableDictionary<NSString *, UIImage *>  *s_badgeImgMap = nil;
static dispatch_once_t s_badgeMapsOnce;
// os_unfair_lock : protège les deux maps sans risque de deadlock depuis n'importe quel thread
// (contrairement à dispatch_sync qui deadlocke si le thread appelant possède déjà la queue)
static os_unfair_lock s_badgeLock = OS_UNFAIR_LOCK_INIT;

static void S7TVEnsureBadgeMaps(void) {
    dispatch_once(&s_badgeMapsOnce, ^{
        s_badgeURLMap = [NSMutableDictionary dictionary];
        s_badgeImgMap = [NSMutableDictionary dictionary];
    });
}
// Image transparente 1x1 — fallback garanti non-nil pour NSTextAttachment.
// UIGraphicsGetImageFromCurrentImageContext peut retourner nil sous pression mémoire.
static UIImage *S7TVPlaceholderImage(CGSize size) {
    if (size.width <= 0) size.width = 1;
    if (size.height <= 0) size.height = 1;
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!img) {
        // Dernier recours : créer un CGImage 1x1 directement
        uint8_t pixel[4] = {0, 0, 0, 0};
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(pixel, 1, 1, 8, 4, cs,
            kCGImageAlphaPremultipliedLast);
        CGImageRef cgImg = CGBitmapContextCreateImage(ctx);
        img = [UIImage imageWithCGImage:cgImg
                                  scale:[UIScreen mainScreen].scale
                            orientation:UIImageOrientationUp];
        CGImageRelease(cgImg);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
    }
    return img;
}



// Charge le JSON de badges depuis l'API publique Twitch et peuple s_badgeURLMap
// Appelé une seule fois (guard interne). Thread-safe via os_unfair_lock.
// NOTE: os_unfair_lock remplace l'ancienne serial queue pour éviter tout deadlock
// depuis le main thread (dispatch_sync sur une serial queue depuis le main thread
// pouvait deadlocker si la queue avait un bloc en attente qui postait sur main).

static BOOL s_globalBadgesLoaded = NO;

static void S7TVLoadGlobalBadges(void) {
    S7TVEnsureBadgeMaps();

    // Guard sans lock (lecture atomique suffisante ici — on double-check sous lock)
    if (s_globalBadgesLoaded) return;

    os_unfair_lock_lock(&s_badgeLock);
    BOOL alreadyLoaded = s_globalBadgesLoaded;
    if (!alreadyLoaded) s_globalBadgesLoaded = YES;
    os_unfair_lock_unlock(&s_badgeLock);
    if (alreadyLoaded) return;

    // API publique sans auth — retourne les badges globaux avec URLs d'image
    NSURL *url = [NSURL URLWithString:
        @"https://badges.twitch.tv/v1/badges/global/display?language=en"];

    [[S7TVBadgeSession() dataTaskWithURL:url
                      completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data || e) {
            // badges.twitch.tv inaccessible (DNS bloqué dans LiveContainer) — on log
            // UNE SEULE FOIS et on ne retry pas (s_globalBadgesLoaded reste YES).
            // Remettre NO créerait une boucle infinie : 950 prefetch → 950 retries.
            [[SevenTVManager sharedManager] log:@"⚠️ Badges indisponibles (DNS bloqué): %@",
             e.localizedDescription];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                             options:0 error:nil];
        // Structure: { "badge_sets": { "broadcaster": { "versions": { "1": { "image_url_1x": "..." } } } } }
        NSDictionary *badgeSets = json[@"badge_sets"];
        if (![badgeSets isKindOfClass:[NSDictionary class]]) return;

        // Construire les entrées dans un dict temporaire hors lock
        NSMutableDictionary *newEntries = [NSMutableDictionary dictionary];
        [badgeSets enumerateKeysAndObjectsUsingBlock:
            ^(NSString *badgeName, NSDictionary *setData, BOOL *stop) {
            NSDictionary *versions = setData[@"versions"];
            if (![versions isKindOfClass:[NSDictionary class]]) return;
            [versions enumerateKeysAndObjectsUsingBlock:
                ^(NSString *version, NSDictionary *vData, BOOL *stop2) {
                NSString *imgURL = vData[@"image_url_2x"] ?: vData[@"image_url_1x"];
                if (imgURL.length) {
                    NSString *key = [NSString stringWithFormat:@"%@/%@", badgeName, version];
                    newEntries[key] = imgURL;
                }
            }];
        }];

        // Écriture sous lock (rapide — juste une fusion de dictionnaires)
        os_unfair_lock_lock(&s_badgeLock);
        S7TVEnsureBadgeMaps();
        [s_badgeURLMap addEntriesFromDictionary:newEntries];
        NSUInteger count = s_badgeURLMap.count;
        os_unfair_lock_unlock(&s_badgeLock);

        [[SevenTVManager sharedManager] log:@"✅ %lu URLs de badges globaux chargées",
         (unsigned long)count];
        // Notifier pour que les cellules déjà affichées se rechargent
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"S7TVBadgesLoaded" object:nil];
        });
    }] resume];
}

// Charge les badges d'un channel spécifique (abonné, bits, etc.)
static void S7TVLoadChannelBadges(NSString *channelID) {
    if (!channelID.length) return;
    S7TVEnsureBadgeMaps();

    NSString *urlStr = [NSString stringWithFormat:
        @"https://badges.twitch.tv/v1/badges/channels/%@/display?language=en", channelID];
    NSURL *url = [NSURL URLWithString:urlStr];

    [[S7TVBadgeSession() dataTaskWithURL:url
                      completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data || e) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                             options:0 error:nil];
        NSDictionary *badgeSets = json[@"badge_sets"];
        if (![badgeSets isKindOfClass:[NSDictionary class]]) return;

        // Construire les entrées dans un dict temporaire hors lock
        NSMutableDictionary *newEntries = [NSMutableDictionary dictionary];
        [badgeSets enumerateKeysAndObjectsUsingBlock:
            ^(NSString *badgeName, NSDictionary *setData, BOOL *stop) {
            NSDictionary *versions = setData[@"versions"];
            if (![versions isKindOfClass:[NSDictionary class]]) return;
            [versions enumerateKeysAndObjectsUsingBlock:
                ^(NSString *version, NSDictionary *vData, BOOL *stop2) {
                NSString *imgURL = vData[@"image_url_2x"] ?: vData[@"image_url_1x"];
                if (imgURL.length) {
                    NSString *key = [NSString stringWithFormat:@"%@/%@",
                                     badgeName, version];
                    newEntries[key] = imgURL;
                }
            }];
        }];

        os_unfair_lock_lock(&s_badgeLock);
        S7TVEnsureBadgeMaps();
        [s_badgeURLMap addEntriesFromDictionary:newEntries];
        os_unfair_lock_unlock(&s_badgeLock);

        [[SevenTVManager sharedManager] log:@"✅ Badges channel %@ chargés", channelID];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"S7TVBadgesLoaded" object:nil];
        });
    }] resume];
}

// Retourne l'image en cache ou nil. Jamais de réseau ici.
static UIImage *S7TVCachedBadgeImage(NSString *badgeKey) {
    S7TVEnsureBadgeMaps();
    os_unfair_lock_lock(&s_badgeLock);
    NSString *imgURL = s_badgeURLMap[badgeKey];
    UIImage  *img    = imgURL ? s_badgeImgMap[imgURL] : nil;
    os_unfair_lock_unlock(&s_badgeLock);
    return img;
}

// Télécharge l'image d'un badge et appelle completion sur main thread
static void S7TVFetchBadgeImage(NSString *badgeKey, void(^completion)(UIImage *)) {
    S7TVEnsureBadgeMaps();

    os_unfair_lock_lock(&s_badgeLock);
    NSString *imgURL = s_badgeURLMap[badgeKey];
    UIImage  *cached = imgURL ? s_badgeImgMap[imgURL] : nil;
    os_unfair_lock_unlock(&s_badgeLock);

    if (!imgURL) {
        // URL inconnue = badge non chargé (badges.twitch.tv probablement inaccessible).
        // Ne pas appeler S7TVLoadGlobalBadges() ici — ça créerait une boucle :
        // cellule → FetchBadgeImage → LoadGlobalBadges → échec réseau → cellule suivante → ...
        if (completion) completion(nil);
        return;
    }

    if (cached) {
        if (completion) completion(cached);
        return;
    }

    NSURL *url = [NSURL URLWithString:imgURL];
    if (!url) { if (completion) completion(nil); return; }

    [[S7TVBadgeSession() dataTaskWithURL:url
                      completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        UIImage *img = nil;
        if (data && !e) {
            img = [UIImage imageWithData:data scale:[UIScreen mainScreen].scale];
            if (img) {
                os_unfair_lock_lock(&s_badgeLock);
                s_badgeImgMap[imgURL] = img;
                os_unfair_lock_unlock(&s_badgeLock);
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(img);
        });
    }] resume];
}


// ────────────────────────────────────────────────────────────
// MARK: - NSTextAttachment custom (taille contrôlée)
// ────────────────────────────────────────────────────────────

@interface S7TVSizedAttachment : NSTextAttachment
@property (nonatomic, assign) CGSize  targetSize;
@property (nonatomic, assign) CGFloat baselineOffset;
@end

@implementation S7TVSizedAttachment

- (CGRect)attachmentBoundsForTextContainer:(NSTextContainer *)textContainer
                      proposedLineFragment:(CGRect)lineFrag
                             glyphPosition:(CGPoint)position
                            characterIndex:(NSUInteger)charIndex {
    // Guard : targetSize zéro crashe le layout engine (division par zéro)
    CGFloat w = self.targetSize.width  > 0 ? self.targetSize.width  : 1.0;
    CGFloat h = self.targetSize.height > 0 ? self.targetSize.height : 1.0;
    return CGRectMake(0, self.baselineOffset, w, h);
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - SevenTVChatCell
// ────────────────────────────────────────────────────────────

@interface SevenTVChatCell ()
@property (nonatomic, strong) UITextView        *textView;
@property (nonatomic, weak)   SevenTVChatMessage *currentMessage;
@end

@implementation SevenTVChatCell

+ (void)initialize {
    if (self == [SevenTVChatCell class]) {
        // Lancer le chargement des badges globaux dès le premier +initialize
        S7TVLoadGlobalBadges();
        // S'abonner au JOIN de channel pour charger les badges channel-specific
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"S7TVChannelJoined"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *n) {
            NSString *channelID = n.userInfo[@"channelID"];
            if (channelID) S7TVLoadChannelBadges(channelID);
        }];
    }
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle  = UITableViewCellSelectionStyleNone;

        UITextView *tv = [[UITextView alloc] init];
        tv.editable           = NO;
        tv.selectable         = NO;
        tv.scrollEnabled      = NO;
        tv.backgroundColor    = [UIColor clearColor];
        tv.textContainerInset = UIEdgeInsetsMake(3, 8, 3, 8);
        tv.textContainer.lineFragmentPadding = 0;
        // CRITIQUE : lineBreakMode doit être WordWrap pour que le layout engine
        // calcule correctement la hauteur avec UITableViewAutomaticDimension.
        // Sans ça, le textView peut retourner une hauteur 0 → crash layout.
        tv.textContainer.lineBreakMode = NSLineBreakByWordWrapping;
        tv.translatesAutoresizingMaskIntoConstraints = NO;

        [self.contentView addSubview:tv];
        [NSLayoutConstraint activateConstraints:@[
            [tv.topAnchor    constraintEqualToAnchor:self.contentView.topAnchor],
            [tv.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [tv.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor],
            [tv.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        ]];

        self.textView = tv;

        // Observer les badges chargés pour se reconfigurer si besoin
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(_badgesLoaded:)
                   name:@"S7TVBadgesLoaded"
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_badgesLoaded:(NSNotification *)n {
    SevenTVChatMessage *msg = self.currentMessage;
    if (msg && msg.badges.count > 0) {
        [self configureWithMessage:msg];
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // Vider immédiatement pour qu'on ne voie jamais l'ancienne emote/texte
    // pendant que configureWithMessage: recalcule le nouvel attributedText.
    self.textView.attributedText = nil;
    self.currentMessage = nil;
}

- (void)configureWithMessage:(SevenTVChatMessage *)message {
    self.currentMessage = message;

    @try {
    [self _unsafeConfigureWithMessage:message];
    } @catch (NSException *ex) {
        [[SevenTVManager sharedManager] log:@"💥 configureWithMessage crash: %@ — %@",
         ex.name, ex.reason];
        // Fallback texte brut
        self.textView.text = [NSString stringWithFormat:@"%@: [erreur rendu]", message.username ?: @"?"];
    }
}

- (void)_unsafeConfigureWithMessage:(SevenTVChatMessage *)message {
    if (message.isDeleted) {
        NSDictionary *deletedAttrs = @{
            NSFontAttributeName: [UIFont italicSystemFontOfSize:13],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.5 alpha:1.0],
        };
        self.textView.attributedText =
            [[NSAttributedString alloc] initWithString:@"[message supprimé]"
                                            attributes:deletedAttrs];
        return;
    }

    NSDictionary *textAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14],
        NSForegroundColorAttributeName: [UIColor whiteColor],
    };
    UIColor *nameColor = message.usernameColor
        ?: [UIColor colorWithRed:0.557 green:0.271 blue:0.878 alpha:1.0];
    NSDictionary *nameAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: nameColor,
    };

    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];

    // ── 1. Badges ─────────────────────────────────────────────────────────────
    // On ne tente les badges que si la map URL est peuplée (badges.twitch.tv accessible).
    // Si la map est vide (DNS bloqué dans LiveContainer), on saute silencieusement.
    BOOL badgesAvailable = NO;
    os_unfair_lock_lock(&s_badgeLock);
    badgesAvailable = (s_badgeURLMap.count > 0);
    os_unfair_lock_unlock(&s_badgeLock);

    if (badgesAvailable) {
    BOOL needsBadgeFetch = NO;
    for (NSDictionary *badge in message.badges) {
        NSString *badgeName    = badge[@"name"];
        NSString *badgeVersion = badge[@"version"] ?: @"1";
        if (!badgeName.length) continue;

        NSString *key = [NSString stringWithFormat:@"%@/%@", badgeName, badgeVersion];
        UIImage *img  = S7TVCachedBadgeImage(key);

        S7TVSizedAttachment *att = [[S7TVSizedAttachment alloc] init];
        att.targetSize     = CGSizeMake(kBadgeTargetSize, kBadgeTargetSize);
        att.baselineOffset = -4.0;

        if (img) {
            att.image = img;
        } else {
            // Placeholder garanti non-nil (image nil dans NSTextAttachment = crash layout engine)
            att.image = S7TVPlaceholderImage(CGSizeMake(kBadgeTargetSize, kBadgeTargetSize));
            needsBadgeFetch = YES;
        }

        [attrStr appendAttributedString:
            [NSAttributedString attributedStringWithAttachment:att]];
        [attrStr appendAttributedString:
            [[NSAttributedString alloc] initWithString:@" " attributes:textAttrs]];
    }

    // Si des badges manquaient → les télécharger et reconfigurer
    if (needsBadgeFetch) {
        __weak SevenTVChatCell *weakSelf = self;
        SevenTVChatMessage *capturedMsg  = message;
        NSArray *badges = message.badges;

        for (NSDictionary *badge in badges) {
            NSString *badgeName    = badge[@"name"];
            NSString *badgeVersion = badge[@"version"] ?: @"1";
            NSString *key = [NSString stringWithFormat:@"%@/%@", badgeName, badgeVersion];
            S7TVFetchBadgeImage(key, ^(UIImage *fetched) {
                // Reconfigurer seulement si la cellule affiche encore ce message
                if (weakSelf && weakSelf.currentMessage == capturedMsg) {
                    [weakSelf configureWithMessage:capturedMsg];
                }
            });
        }
    }
    } // fin if (badgesAvailable)

    // ── 2. Pseudo en couleur ──────────────────────────────────────────────────
    NSString *nameStr = [NSString stringWithFormat:@"%@: ", message.username];
    [attrStr appendAttributedString:
        [[NSAttributedString alloc] initWithString:nameStr attributes:nameAttrs]];

    // ── 3. Segments texte + emotes ────────────────────────────────────────────
    for (NSDictionary *seg in message.segments) {
        NSString *type = seg[@"type"];

        if ([type isEqualToString:@"text"]) {
            NSString *val = seg[@"value"];
            if (val.length) {
                [attrStr appendAttributedString:
                    [[NSAttributedString alloc] initWithString:val attributes:textAttrs]];
            }

        } else if ([type isEqualToString:@"emote"]) {
            CGFloat w = [seg[@"width"]  floatValue];
            CGFloat h = [seg[@"height"] floatValue];
            CGSize targetSize;
            if (w > 0 && h > 0) {
                targetSize = CGSizeMake(kEmoteTargetHeight * (w / h), kEmoteTargetHeight);
            } else {
                targetSize = CGSizeMake(kEmoteTargetHeight, kEmoteTargetHeight);
            }

            if (attrStr.length > 0) {
                unichar last = [attrStr.string characterAtIndex:attrStr.length - 1];
                if (last != ' ') {
                    [attrStr appendAttributedString:
                        [[NSAttributedString alloc] initWithString:@" " attributes:textAttrs]];
                }
            }

            // Lookup cache via URL CDN réelle
            NSString *emoteID = seg[@"emoteID"];
            NSString *cdnURLStr = [NSString stringWithFormat:
                @"https://cdn.7tv.app/emote/%@/4x.webp", emoteID];
            NSCachedURLResponse *cached =
                [[SevenTVURLProtocol sharedEmoteCache] cachedResponseForRequest:
                    [NSURLRequest requestWithURL:[NSURL URLWithString:cdnURLStr]]];

            S7TVSizedAttachment *attachment = [[S7TVSizedAttachment alloc] init];
            attachment.targetSize     = targetSize;
            attachment.baselineOffset = -5.0;

            UIImage *emoteImg = nil;
            if (cached.data) {
                emoteImg = [UIImage imageWithData:cached.data
                                           scale:[UIScreen mainScreen].scale];
            }

            if (emoteImg) {
                attachment.image = emoteImg;
            } else {
                // Image pas encore en cache → placeholder + prefetch + reconfigure
                attachment.image = S7TVPlaceholderImage(targetSize);

                __weak SevenTVChatCell *weakSelf = self;
                SevenTVChatMessage *capturedMsg  = message;
                [SevenTVURLProtocol prefetchEmoteID:emoteID completion:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // Reconfigurer seulement si la cellule affiche encore ce message
                        if (weakSelf && weakSelf.currentMessage == capturedMsg) {
                            [weakSelf configureWithMessage:capturedMsg];
                        }
                    });
                }];
            }

            [attrStr appendAttributedString:
                [NSAttributedString attributedStringWithAttachment:attachment]];
            [attrStr appendAttributedString:
                [[NSAttributedString alloc] initWithString:@" " attributes:textAttrs]];
        }
    }

    self.textView.attributedText = attrStr;
}

@end
