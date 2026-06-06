/*
 * SevenTVChatCell.m
 *
 * Layout : NSTextAttachment pour les emotes et badges dans un NSAttributedString,
 * affiché dans un UITextView non-scrollable (self-sizing).
 *
 * FIX v2 :
 *   - Emotes : lookup cache via l'URL CDN réelle (cdn.7tv.app/emote/ID/4x.webp)
 *              et non plus l'URL Twitch fake. Les deux étaient différentes → miss sys.
 *   - Badges : parsés depuis msg.badges (tableau de @{name, version}) et affichés
 *              à gauche du pseudo via NSTextAttachment, images depuis l'API Twitch
 *              Badges (cdn.7tv.app ne fournit pas les badges Twitch).
 *
 * Taille emotes : hauteur cible 22pt (ligne de texte 14pt), largeur = 22 * (w/h).
 * Taille badges : 18×18pt, légèrement plus petit que les emotes.
 */

#import "SevenTVChatCell.h"
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"

NSString * const kSevenTVChatCellReuseID = @"SevenTVChatCell";

static const CGFloat kEmoteTargetHeight = 22.0;
static const CGFloat kBadgeTargetSize   = 18.0;

// Cache mémoire des images de badges (URL → UIImage)
// Partagé entre toutes les cellules, jamais vidé (peu d'entrées uniques)
static NSMutableDictionary<NSString *, UIImage *> *s_badgeImageCache = nil;
static dispatch_once_t s_badgeCacheOnce;

static NSMutableDictionary<NSString *, UIImage *> *S7TVBadgeImageCache(void) {
    dispatch_once(&s_badgeCacheOnce, ^{
        s_badgeImageCache = [NSMutableDictionary dictionary];
    });
    return s_badgeImageCache;
}


// ────────────────────────────────────────────────────────────
// MARK: - NSTextAttachment custom (taille contrôlée)
// ────────────────────────────────────────────────────────────

@interface S7TVSizedAttachment : NSTextAttachment
@property (nonatomic, assign) CGSize targetSize;
@property (nonatomic, assign) CGFloat baselineOffset; // décalage vertical (négatif = descend)
@end

@implementation S7TVSizedAttachment

- (CGRect)attachmentBoundsForTextContainer:(NSTextContainer *)textContainer
                      proposedLineFragment:(CGRect)lineFrag
                             glyphPosition:(CGPoint)position
                            characterIndex:(NSUInteger)charIndex {
    return CGRectMake(0, self.baselineOffset, self.targetSize.width, self.targetSize.height);
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - Helpers
// ────────────────────────────────────────────────────────────

// Construit une URL d'image de badge Twitch global (channel = nil) ou channel-specific
// Format: https://static-cdn.jtvnw.net/badges/v1/{set_id}/{version}/1
static NSString *S7TVBadgeImageURL(NSString *badgeName, NSString *badgeVersion) {
    // Twitch héberge les badges globaux + channel sur le même endpoint
    // On utilise les badges v1 (PNG) car WebP n'est pas toujours dispo
    return [NSString stringWithFormat:
        @"https://static-cdn.jtvnw.net/badges/v1/%@/%@/1",
        badgeName, badgeVersion ?: @"1"];
}

// Crée un attachment badge avec l'image donnée (ou placeholder si nil)
static S7TVSizedAttachment *S7TVMakeBadgeAttachment(UIImage * _Nullable img) {
    CGSize sz = CGSizeMake(kBadgeTargetSize, kBadgeTargetSize);
    S7TVSizedAttachment *att = [[S7TVSizedAttachment alloc] init];
    att.targetSize     = sz;
    att.baselineOffset = -4.0; // aligner verticalement avec le texte 14pt

    if (img) {
        att.image = img;
    } else {
        // Placeholder transparent (invisible = propre)
        UIGraphicsBeginImageContextWithOptions(sz, NO, 0);
        att.image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    return att;
}

// Télécharge l'image d'un badge de façon asynchrone et recharge la cellule
// via une notification (on ne connaît pas l'indexPath depuis ici)
static void S7TVFetchBadgeImage(NSString *urlStr, void(^completion)(UIImage *)) {
    if (!urlStr.length) { if (completion) completion(nil); return; }

    // Check cache mémoire
    UIImage *cached = S7TVBadgeImageCache()[urlStr];
    if (cached) { if (completion) completion(cached); return; }

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { if (completion) completion(nil); return; }

    // Téléchargement via NSURLSession partagé (badges = petits PNG, pas besoin
    // du cache CDN isolé)
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.protocolClasses = @[]; // éviter la boucle SevenTVURLProtocol
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        UIImage *img = nil;
        if (data && !e) {
            img = [UIImage imageWithData:data scale:[UIScreen mainScreen].scale];
            if (img) S7TVBadgeImageCache()[urlStr] = img;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(img);
        });
    }] resume];
}


// ────────────────────────────────────────────────────────────
// MARK: - SevenTVChatCell
// ────────────────────────────────────────────────────────────

@interface SevenTVChatCell ()
@property (nonatomic, strong) UITextView *textView;
// Garde une référence au message en cours pour les reloads async (badges)
@property (nonatomic, weak)   SevenTVChatMessage *currentMessage;
@end

@implementation SevenTVChatCell

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
        tv.translatesAutoresizingMaskIntoConstraints = NO;

        [self.contentView addSubview:tv];
        [NSLayoutConstraint activateConstraints:@[
            [tv.topAnchor    constraintEqualToAnchor:self.contentView.topAnchor],
            [tv.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [tv.leadingAnchor  constraintEqualToAnchor:self.contentView.leadingAnchor],
            [tv.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        ]];

        self.textView = tv;
    }
    return self;
}

- (void)configureWithMessage:(SevenTVChatMessage *)message {
    self.currentMessage = message;

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

    // Attributs partagés
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

    // ── 1. Badges ────────────────────────────────────────────────────────────
    for (NSDictionary *badge in message.badges) {
        NSString *badgeName    = badge[@"name"];
        NSString *badgeVersion = badge[@"version"] ?: @"1";
        if (!badgeName.length) continue;

        NSString *urlStr = S7TVBadgeImageURL(badgeName, badgeVersion);
        UIImage *img = S7TVBadgeImageCache()[urlStr];

        S7TVSizedAttachment *att = S7TVMakeBadgeAttachment(img);
        [attrStr appendAttributedString:
            [NSAttributedString attributedStringWithAttachment:att]];
        // Petit espace après chaque badge
        [attrStr appendAttributedString:
            [[NSAttributedString alloc] initWithString:@" " attributes:textAttrs]];

        // Si l'image n'était pas en cache → télécharger et reconfigurer
        if (!img) {
            __weak SevenTVChatCell *weakSelf = self;
            SevenTVChatMessage *capturedMsg  = message;
            S7TVFetchBadgeImage(urlStr, ^(UIImage *fetched) {
                // Vérifier que la cellule affiche encore le même message
                if (weakSelf.currentMessage == capturedMsg && fetched) {
                    [weakSelf configureWithMessage:capturedMsg];
                }
            });
        }
    }

    // ── 2. Pseudo en couleur ────────────────────────────────────────────────
    NSString *nameStr = [NSString stringWithFormat:@"%@: ", message.username];
    [attrStr appendAttributedString:
        [[NSAttributedString alloc] initWithString:nameStr attributes:nameAttrs]];

    // ── 3. Segments texte + emotes ───────────────────────────────────────────
    for (NSDictionary *seg in message.segments) {
        NSString *type = seg[@"type"];

        if ([type isEqualToString:@"text"]) {
            NSString *val = seg[@"value"];
            if (val.length) {
                [attrStr appendAttributedString:
                    [[NSAttributedString alloc] initWithString:val attributes:textAttrs]];
            }

        } else if ([type isEqualToString:@"emote"]) {
            // ── Taille adaptive ──────────────────────────────────────────────
            CGFloat w = [seg[@"width"]  floatValue];
            CGFloat h = [seg[@"height"] floatValue];
            CGSize targetSize;
            if (w > 0 && h > 0) {
                targetSize = CGSizeMake(kEmoteTargetHeight * (w / h), kEmoteTargetHeight);
            } else {
                targetSize = CGSizeMake(kEmoteTargetHeight, kEmoteTargetHeight);
            }

            // Espace avant l'emote si nécessaire
            if (attrStr.length > 0) {
                unichar last = [attrStr.string characterAtIndex:attrStr.length - 1];
                if (last != ' ') {
                    [attrStr appendAttributedString:
                        [[NSAttributedString alloc] initWithString:@" " attributes:textAttrs]];
                }
            }

            // ── Lookup image depuis le cache CDN réel ────────────────────────
            // IMPORTANT: la clé de cache est l'URL CDN réelle (cdn.7tv.app),
            // pas l'URL Twitch fake (static.twitchcdn.net). C'était la cause
            // des carrés noirs : deux URLs différentes → cache miss systématique.
            NSString *emoteID = seg[@"emoteID"];
            NSString *cdnURLStr = [NSString stringWithFormat:
                @"https://cdn.7tv.app/emote/%@/4x.webp", emoteID];
            NSURLRequest *cacheReq = [NSURLRequest requestWithURL:
                [NSURL URLWithString:cdnURLStr]];
            NSCachedURLResponse *cached =
                [[SevenTVURLProtocol sharedEmoteCache] cachedResponseForRequest:cacheReq];

            S7TVSizedAttachment *attachment = [[S7TVSizedAttachment alloc] init];
            attachment.targetSize     = targetSize;
            // Décalage vertical : centre l'emote sur la ligne de texte 14pt
            // lineFrag.height ≈ 20pt → offset = -(emoteH - font.capHeight) / 2
            attachment.baselineOffset = -5.0;

            if (cached.data) {
                UIImage *img = [UIImage imageWithData:cached.data
                                               scale:[UIScreen mainScreen].scale];
                if (img) attachment.image = img;
            }

            // Placeholder si toujours pas d'image (ne devrait pas arriver si
            // le prefetch a fonctionné, mais sécurité)
            if (!attachment.image) {
                UIGraphicsBeginImageContextWithOptions(targetSize, NO, 0);
                [[UIColor colorWithWhite:0.25 alpha:0.6] setFill];
                [[UIBezierPath bezierPathWithRoundedRect:
                    CGRectMake(0, 0, targetSize.width, targetSize.height)
                    cornerRadius:3] fill];
                attachment.image = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
            }

            [attrStr appendAttributedString:
                [NSAttributedString attributedStringWithAttachment:attachment]];

            // Espace après l'emote
            [attrStr appendAttributedString:
                [[NSAttributedString alloc] initWithString:@" " attributes:textAttrs]];
        }
    }

    self.textView.attributedText = attrStr;
}

@end
