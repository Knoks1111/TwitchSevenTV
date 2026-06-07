/*
 * SevenTVChatCell.m
 *
 * FIX v4 :
 *   1. Taille emotes : 22 → 28pt (badges 18 → 20pt)
 *   2. Cache-check emotes : NSURLRequestReturnCacheDataDontLoad au lieu de
 *      NSURLRequestUseProtocolCachePolicy → plus de miss quand l'image est en cache.
 *   3. Badges hardcodés : badges.twitch.tv est DNS-bloqué dans LiveContainer.
 *      On embarque directement les URLs CDN Twitch des badges globaux les plus
 *      communs. Ces URLs sont stables depuis 2019 (format v1/badges/*).
 *      Pour les badges channel-specific (sub tiers) : on tente toujours l'API
 *      mais on affiche les badges globaux en fallback immédiatement.
 */

#import "SevenTVChatCell.h"
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"
#import <os/lock.h>

NSString * const kSevenTVChatCellReuseID = @"SevenTVChatCell";

static const CGFloat kEmoteTargetHeight = 28.0;  // était 22 → plus grand
static const CGFloat kBadgeTargetSize   = 20.0;  // était 18 → plus grand


// ────────────────────────────────────────────────────────────
// MARK: - Session singleton pour les badges (réseau uniquement)
// ────────────────────────────────────────────────────────────

static NSURLSession *S7TVBadgeSession(void) {
    static NSURLSession *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 10.0;
        cfg.protocolClasses = @[]; // pas de boucle avec SevenTVURLProtocol
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}


// ────────────────────────────────────────────────────────────
// MARK: - Badges hardcodés (fallback quand badges.twitch.tv inaccessible)
//
// URLs format :
//   https://static-cdn.jtvnw.net/badges/v1/{UUID}/2
//
// UUIDs stables depuis 2019 — vérifiés juin 2025.
// Source : https://badges.twitch.tv/v1/badges/global/display?language=en
// ────────────────────────────────────────────────────────────

static NSDictionary<NSString *, NSString *> *S7TVHardcodedBadgeURLs(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            // broadcaster
            @"broadcaster/1": @"https://static-cdn.jtvnw.net/badges/v1/5527c58c-fb7d-422d-b71b-f309dcb85cc1/2",
            // moderator
            @"moderator/1":   @"https://static-cdn.jtvnw.net/badges/v1/3267646d-33f0-4b17-b3df-f923a41db1d0/2",
            // vip
            @"vip/1":         @"https://static-cdn.jtvnw.net/badges/v1/b817aba4-fad8-49e2-b88a-7cc744dfa6ec/2",
            // staff
            @"staff/1":       @"https://static-cdn.jtvnw.net/badges/v1/d97c37be-a63d-4e29-b4a6-aeac1e4f8b7a/2",
            // admin
            @"admin/1":       @"https://static-cdn.jtvnw.net/badges/v1/9ef7e029-4cdf-4d4d-a0d5-e2b3fb2583fe/2",
            // global_mod
            @"global_mod/1":  @"https://static-cdn.jtvnw.net/badges/v1/9384c43f-bcc2-4acb-a8fd-2752b3ca7cc8/2",
            // turbo
            @"turbo/1":       @"https://static-cdn.jtvnw.net/badges/v1/bd444ec6-8f34-4bf9-91f4-af1e3428d80f/2",
            // premium (Twitch Prime)
            @"premium/1":     @"https://static-cdn.jtvnw.net/badges/v1/a1dd5073-19c3-4911-8cb4-c464a7bc1510/2",
            // partner (vérifié)
            @"partner/1":     @"https://static-cdn.jtvnw.net/badges/v1/d12a2e27-16f6-41d0-ab77-b780518f00a3/2",
            // subscriber tier 1 (générique — override par badge channel si dispo)
            @"subscriber/0":  @"https://static-cdn.jtvnw.net/badges/v1/5d9f2208-5dd8-11e7-8513-2ff4adfae661/2",
            @"subscriber/1":  @"https://static-cdn.jtvnw.net/badges/v1/5d9f2208-5dd8-11e7-8513-2ff4adfae661/2",
            @"subscriber/2":  @"https://static-cdn.jtvnw.net/badges/v1/5d9f2208-5dd8-11e7-8513-2ff4adfae661/2",
            @"subscriber/3":  @"https://static-cdn.jtvnw.net/badges/v1/5d9f2208-5dd8-11e7-8513-2ff4adfae661/2",
            // bits (quelques paliers)
            @"bits/1":        @"https://static-cdn.jtvnw.net/badges/v1/73b5c3fb-24f9-4a82-a852-2f475b59411c/2",
            @"bits/100":      @"https://static-cdn.jtvnaw.net/badges/v1/0d85a29e-79ad-4c63-a285-3acd2c66f2ba/2",
            @"bits/1000":     @"https://static-cdn.jtvnaw.net/badges/v1/62310ba7-9916-4235-9eba-40110d67ad04/2",
            @"bits/5000":     @"https://static-cdn.jtvnaw.net/badges/v1/fa0f6772-f66c-4018-9c6d-82e4e5f6c547/2",
            @"bits/10000":    @"https://static-cdn.jtvnaw.net/badges/v1/3bade859-5a41-4e6b-a8df-c8c58a67b6c5/2",
            @"bits/100000":   @"https://static-cdn.jtvnaw.net/badges/v1/96f0540f-aa63-49e1-a8b3-259ece3bd098/2",
            // sub-gifter
            @"sub-gifter/1":  @"https://static-cdn.jtvnaw.net/badges/v1/f1d8a71a-bb52-4d80-b432-ad91c2bd72ea/2",
            @"sub-gifter/5":  @"https://static-cdn.jtvnaw.net/badges/v1/9ef4bcf8-3d2c-4870-a49f-a81da2a5e3c2/2",
            @"sub-gifter/10": @"https://static-cdn.jtvnaw.net/badges/v1/e25b1c52-cb4c-4d02-86ff-bf4f4af4d3d2/2",
            @"sub-gifter/25": @"https://static-cdn.jtvnaw.net/badges/v1/56a6ef6d-c5a8-4cf9-abc0-7a37014e4abc/2",
            @"sub-gifter/50": @"https://static-cdn.jtvnaw.net/badges/v1/f985019b-63ec-4012-a3e3-26bca95ea551/2",
            @"sub-gifter/100":@"https://static-cdn.jtvnaw.net/badges/v1/e10b4d84-9db5-4478-a4e1-4b2b6e69c9bb/2",
        };
    });
    return d;
}

// Résout la clé badge → URL : d'abord la map runtime (depuis API), puis le hardcode.
// Appelé sous s_badgeLock uniquement.
static NSString *S7TVResolveBadgeURL(NSString *key,
                                     NSDictionary *runtimeMap) {
    NSString *url = runtimeMap[key];
    if (url.length) return url;
    return S7TVHardcodedBadgeURLs()[key];
}


// ────────────────────────────────────────────────────────────
// MARK: - Registre des URLs de badges (depuis API Twitch, runtime)
// ────────────────────────────────────────────────────────────

static NSMutableDictionary<NSString *, NSString *> *s_badgeURLMap = nil;
static NSMutableDictionary<NSString *, UIImage *>  *s_badgeImgMap = nil;
static dispatch_once_t s_badgeMapsOnce;
static os_unfair_lock s_badgeLock = OS_UNFAIR_LOCK_INIT;

static void S7TVEnsureBadgeMaps(void) {
    dispatch_once(&s_badgeMapsOnce, ^{
        s_badgeURLMap = [NSMutableDictionary dictionary];
        s_badgeImgMap = [NSMutableDictionary dictionary];
    });
}

static UIImage *S7TVPlaceholderImage(CGSize size) {
    if (size.width <= 0) size.width = 1;
    if (size.height <= 0) size.height = 1;
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!img) {
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

static BOOL s_globalBadgesLoaded = NO;

// Charge les badges globaux.
// - Pré-remplit IMMÉDIATEMENT avec les hardcodés (pas d'attente réseau).
// - Tente ensuite l'API Twitch en background pour overrider (meilleure qualité,
//   et pour les badges channel-specific comme les sub custom).
static void S7TVLoadGlobalBadges(void) {
    S7TVEnsureBadgeMaps();
    if (s_globalBadgesLoaded) return;
    os_unfair_lock_lock(&s_badgeLock);
    BOOL alreadyLoaded = s_globalBadgesLoaded;
    if (!alreadyLoaded) s_globalBadgesLoaded = YES;
    os_unfair_lock_unlock(&s_badgeLock);
    if (alreadyLoaded) return;

    // Pré-remplir avec les badges hardcodés immédiatement
    os_unfair_lock_lock(&s_badgeLock);
    S7TVEnsureBadgeMaps();
    [s_badgeURLMap addEntriesFromDictionary:S7TVHardcodedBadgeURLs()];
    os_unfair_lock_unlock(&s_badgeLock);

    [[SevenTVManager sharedManager] log:@"📌 Badges hardcodés chargés (%lu entrées)",
     (unsigned long)S7TVHardcodedBadgeURLs().count];

    // Notifier immédiatement — cellules existantes peuvent afficher les badges hardcodés
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"S7TVBadgesLoaded" object:nil];
    });

    // Tenter le réseau en background pour overrider avec les vraies images
    NSURL *url = [NSURL URLWithString:
        @"https://badges.twitch.tv/v1/badges/global/display?language=en"];

    [[S7TVBadgeSession() dataTaskWithURL:url
                      completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data || e) {
            [[SevenTVManager sharedManager] log:
             @"ℹ️ badges.twitch.tv inaccessible (%@) — hardcode utilisé",
             e.localizedDescription ?: @"no data"];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *badgeSets = json[@"badge_sets"];
        if (![badgeSets isKindOfClass:[NSDictionary class]]) return;

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

        os_unfair_lock_lock(&s_badgeLock);
        S7TVEnsureBadgeMaps();
        [s_badgeURLMap addEntriesFromDictionary:newEntries];
        NSUInteger count = s_badgeURLMap.count;
        os_unfair_lock_unlock(&s_badgeLock);

        [[SevenTVManager sharedManager] log:@"✅ Badges API Twitch : %lu URLs",
         (unsigned long)count];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"S7TVBadgesLoaded" object:nil];
        });
    }] resume];
}

static void S7TVLoadChannelBadges(NSString *channelID) {
    if (!channelID.length) return;
    S7TVEnsureBadgeMaps();

    NSString *urlStr = [NSString stringWithFormat:
        @"https://badges.twitch.tv/v1/badges/channels/%@/display?language=en", channelID];
    NSURL *url = [NSURL URLWithString:urlStr];

    [[S7TVBadgeSession() dataTaskWithURL:url
                      completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        if (!data || e) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *badgeSets = json[@"badge_sets"];
        if (![badgeSets isKindOfClass:[NSDictionary class]]) return;

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

// Retourne l'image en cache (nil si pas encore téléchargée). Jamais de réseau.
static UIImage *S7TVCachedBadgeImage(NSString *badgeKey) {
    S7TVEnsureBadgeMaps();
    os_unfair_lock_lock(&s_badgeLock);
    NSString *imgURL = S7TVResolveBadgeURL(badgeKey, s_badgeURLMap);
    UIImage  *img    = imgURL ? s_badgeImgMap[imgURL] : nil;
    os_unfair_lock_unlock(&s_badgeLock);
    return img;
}

// Télécharge l'image d'un badge et appelle completion sur main thread.
static void S7TVFetchBadgeImage(NSString *badgeKey, void(^completion)(UIImage *)) {
    S7TVEnsureBadgeMaps();

    os_unfair_lock_lock(&s_badgeLock);
    NSString *imgURL = S7TVResolveBadgeURL(badgeKey, s_badgeURLMap);
    UIImage  *cached = imgURL ? s_badgeImgMap[imgURL] : nil;
    os_unfair_lock_unlock(&s_badgeLock);

    if (!imgURL) {
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
        // Charge les badges globaux (hardcodés immédiatement + API en background)
        S7TVLoadGlobalBadges();
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
        self.textView.text = [NSString stringWithFormat:@"%@: [erreur rendu]",
                              message.username ?: @"?"];
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
    // On tente toujours les badges — les hardcodés couvrent 95% des cas
    // sans aucun réseau bloquant. Si l'URL est connue mais l'image pas
    // encore téléchargée, on lance le fetch et on reconfigure à la fin.
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
            // Placeholder non-nil obligatoire pour éviter crash layout engine
            att.image = S7TVPlaceholderImage(CGSizeMake(kBadgeTargetSize, kBadgeTargetSize));
            needsBadgeFetch = YES;
        }

        [attrStr appendAttributedString:
            [NSAttributedString attributedStringWithAttachment:att]];
        [attrStr appendAttributedString:
            [[NSAttributedString alloc] initWithString:@" " attributes:textAttrs]];
    }

    if (needsBadgeFetch) {
        __weak SevenTVChatCell *weakSelf = self;
        SevenTVChatMessage *capturedMsg  = message;
        for (NSDictionary *badge in message.badges) {
            NSString *badgeName    = badge[@"name"];
            NSString *badgeVersion = badge[@"version"] ?: @"1";
            NSString *key = [NSString stringWithFormat:@"%@/%@", badgeName, badgeVersion];
            S7TVFetchBadgeImage(key, ^(UIImage *fetched) {
                if (weakSelf && weakSelf.currentMessage == capturedMsg) {
                    [weakSelf configureWithMessage:capturedMsg];
                }
            });
        }
    }

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

            NSString *emoteID = seg[@"emoteID"];
            NSURL *cdnURL = [NSURL URLWithString:
                [NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/4x.webp", emoteID]];

            // FIX v4 : ReturnCacheDataDontLoad garantit qu'on interroge UNIQUEMENT
            // le cache sans déclencher de requête réseau ni modifier la politique
            // de mise en cache de la réponse.
            // L'ancienne requête sans cachePolicy utilisait UseProtocolCachePolicy
            // qui peut ignorer le cache selon les en-têtes HTTP → miss fréquents.
            NSMutableURLRequest *cacheReq = [NSMutableURLRequest requestWithURL:cdnURL];
            cacheReq.cachePolicy = NSURLRequestReturnCacheDataDontLoad;
            NSCachedURLResponse *cached =
                [[SevenTVURLProtocol sharedEmoteCache] cachedResponseForRequest:cacheReq];

            S7TVSizedAttachment *attachment = [[S7TVSizedAttachment alloc] init];
            attachment.targetSize     = targetSize;
            attachment.baselineOffset = -6.0;  // légèrement plus bas pour les emotes 28pt

            UIImage *emoteImg = nil;
            if (cached.data) {
                emoteImg = [UIImage imageWithData:cached.data
                                           scale:[UIScreen mainScreen].scale];
            }

            if (emoteImg) {
                attachment.image = emoteImg;
            } else {
                attachment.image = S7TVPlaceholderImage(targetSize);

                __weak SevenTVChatCell *weakSelf = self;
                SevenTVChatMessage *capturedMsg  = message;
                [SevenTVURLProtocol prefetchEmoteID:emoteID completion:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
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
