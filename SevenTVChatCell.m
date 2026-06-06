/*
 * SevenTVChatCell.m
 *
 * Layout : NSTextAttachment pour les emotes dans un NSAttributedString,
 * affiché dans un UITextView non-scrollable (self-sizing).
 *
 * Contrairement à Twitch natif, ici c'est NOTRE UITextView → on contrôle
 * exactement les bounds des NSTextAttachment → taille adaptive garantie.
 *
 * Taille emotes : hauteur cible 28pt, largeur = 28 * (w/h).
 * Si les dimensions réelles sont inconnues → 28×28pt par défaut.
 */

#import "SevenTVChatCell.h"
#import "SevenTVManager.h"
#import "SevenTVURLProtocol.h"

NSString * const kSevenTVChatCellReuseID = @"SevenTVChatCell";

static const CGFloat kEmoteTargetHeight = 28.0;

// ────────────────────────────────────────────────────────────
// MARK: - NSTextAttachment custom (emote avec taille contrôlée)
// ────────────────────────────────────────────────────────────

@interface S7TVEmoteAttachment : NSTextAttachment
@property (nonatomic, assign) CGSize targetSize;
@end

@implementation S7TVEmoteAttachment

- (CGRect)attachmentBoundsForTextContainer:(NSTextContainer *)textContainer
                      proposedLineFragment:(CGRect)lineFrag
                             glyphPosition:(CGPoint)position
                            characterIndex:(NSUInteger)charIndex {
    return CGRectMake(0, -6, self.targetSize.width, self.targetSize.height);
}

@end


// ────────────────────────────────────────────────────────────
// MARK: - SevenTVChatCell
// ────────────────────────────────────────────────────────────

@interface SevenTVChatCell ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation SevenTVChatCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle  = UITableViewCellSelectionStyleNone;

        UITextView *tv = [[UITextView alloc] init];
        tv.editable          = NO;
        tv.selectable        = NO;
        tv.scrollEnabled     = NO;
        tv.backgroundColor   = [UIColor clearColor];
        tv.textContainerInset = UIEdgeInsetsMake(4, 8, 4, 8);
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
    if (message.isDeleted) {
        NSDictionary *deletedAttrs = @{
            NSFontAttributeName: [UIFont italicSystemFontOfSize:14],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.5 alpha:1.0],
        };
        self.textView.attributedText =
            [[NSAttributedString alloc] initWithString:@"[message supprimé]"
                                            attributes:deletedAttrs];
        return;
    }

    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];

    // ── Pseudo en couleur ──────────────────────────────────────────────────────
    UIColor *nameColor = message.usernameColor ?: [UIColor colorWithRed:0.557 green:0.271 blue:0.878 alpha:1.0];
    NSDictionary *nameAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: nameColor,
    };
    NSString *nameStr = [NSString stringWithFormat:@"%@: ", message.username];
    [attrStr appendAttributedString:
        [[NSAttributedString alloc] initWithString:nameStr attributes:nameAttrs]];

    // ── Segments texte + emotes ────────────────────────────────────────────────
    NSDictionary *textAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14],
        NSForegroundColorAttributeName: [UIColor whiteColor],
    };

    for (NSDictionary *seg in message.segments) {
        NSString *type = seg[@"type"];

        if ([type isEqualToString:@"text"]) {
            NSString *val = seg[@"value"];
            if (val.length) {
                [attrStr appendAttributedString:
                    [[NSAttributedString alloc] initWithString:val attributes:textAttrs]];
            }

        } else if ([type isEqualToString:@"emote"]) {
            // Calculer la taille cible adaptive
            CGFloat w = [seg[@"width"] floatValue];
            CGFloat h = [seg[@"height"] floatValue];
            CGSize targetSize;
            if (w > 0 && h > 0) {
                targetSize = CGSizeMake(kEmoteTargetHeight * (w / h), kEmoteTargetHeight);
            } else {
                targetSize = CGSizeMake(kEmoteTargetHeight, kEmoteTargetHeight);
            }

            // Espace avant l'emote (sauf si premier caractère)
            if (attrStr.length > 0) {
                NSString *lastChar = [attrStr.string substringFromIndex:attrStr.length - 1];
                if (![lastChar isEqualToString:@" "]) {
                    [attrStr appendAttributedString:
                        [[NSAttributedString alloc] initWithString:@" " attributes:textAttrs]];
                }
            }

            // Créer l'attachment
            S7TVEmoteAttachment *attachment = [[S7TVEmoteAttachment alloc] init];
            attachment.targetSize = targetSize;

            // Charger l'image depuis le cache NSURLCache de SevenTVURLProtocol
            NSString *emoteID = seg[@"emoteID"];
            NSString *urlStr = [NSString stringWithFormat:
                @"https://static.twitchcdn.net/assets/emoticons/v2/7tv_%@/default/dark/2.0",
                emoteID];
            NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
            NSCachedURLResponse *cached = [[SevenTVURLProtocol sharedEmoteCache] cachedResponseForRequest:req];
            if (cached.data) {
                UIImage *img = [UIImage imageWithData:cached.data scale:[UIScreen mainScreen].scale];
                if (img) attachment.image = img;
            }

            // Image placeholder si pas encore en cache (gris)
            if (!attachment.image) {
                UIGraphicsBeginImageContextWithOptions(targetSize, NO, 0);
                [[UIColor colorWithWhite:0.3 alpha:0.5] setFill];
                UIBezierPath *r = [UIBezierPath bezierPathWithRoundedRect:
                    CGRectMake(0, 0, targetSize.width, targetSize.height)
                    cornerRadius:3];
                [r fill];
                attachment.image = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();

                // Charger l'image en arrière-plan et reloader si besoin
                // (hack simple : on ne connaît pas la cellule depuis ici,
                //  mais le prefetch de SevenTVURLProtocol aura déjà tout mis en cache)
            }

            NSAttributedString *emoteSpacer =
                [NSAttributedString attributedStringWithAttachment:attachment];
            [attrStr appendAttributedString:emoteSpacer];

            // Espace après l'emote
            [attrStr appendAttributedString:
                [[NSAttributedString alloc] initWithString:@" " attributes:textAttrs]];
        }
    }

    self.textView.attributedText = attrStr;
}

@end
