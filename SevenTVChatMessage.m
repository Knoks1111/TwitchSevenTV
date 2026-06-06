/*
 * SevenTVChatMessage.m
 */

#import "SevenTVChatMessage.h"
#import "SevenTVManager.h"

@implementation SevenTVChatMessage

+ (instancetype)messageFromIRCString:(NSString *)ircLine {
    if (!ircLine.length) return nil;

    // On ne traite que les PRIVMSG
    // Format: @tags :user!user@user.tmi.twitch.tv PRIVMSG #channel :message text
    if (![ircLine containsString:@" PRIVMSG "]) return nil;

    SevenTVChatMessage *msg = [[SevenTVChatMessage alloc] init];
    msg.isDeleted = NO;

    // ── 1. Extraire les tags (@key=value;key=value) ───────────────────────────
    NSMutableDictionary<NSString *, NSString *> *tags = [NSMutableDictionary dictionary];
    if ([ircLine hasPrefix:@"@"]) {
        NSRange spaceRange = [ircLine rangeOfString:@" "];
        if (spaceRange.location != NSNotFound) {
            NSString *tagStr = [ircLine substringWithRange:NSMakeRange(1, spaceRange.location - 1)];
            for (NSString *pair in [tagStr componentsSeparatedByString:@";"]) {
                NSRange eq = [pair rangeOfString:@"="];
                if (eq.location != NSNotFound) {
                    NSString *key = [pair substringToIndex:eq.location];
                    NSString *val = [pair substringFromIndex:eq.location + 1];
                    tags[key] = val;
                }
            }
        }
    }

    msg.messageId = tags[@"id"] ?: [[NSUUID UUID] UUIDString];

    // ── 2. Pseudo et couleur ──────────────────────────────────────────────────
    NSString *displayName = tags[@"display-name"];
    if (!displayName.length) {
        // Fallback : extraire depuis :user!...
        NSRange colonRange = [ircLine rangeOfString:@":"];
        NSRange exclamRange = [ircLine rangeOfString:@"!"];
        if (colonRange.location != NSNotFound && exclamRange.location != NSNotFound
            && exclamRange.location > colonRange.location) {
            displayName = [ircLine substringWithRange:
                NSMakeRange(colonRange.location + 1,
                            exclamRange.location - colonRange.location - 1)];
        }
    }
    msg.username = displayName.length ? displayName : @"anonymous";

    NSString *colorStr = tags[@"color"];
    if (colorStr.length == 7 && [colorStr hasPrefix:@"#"]) {
        unsigned int rgb = 0;
        [[NSScanner scannerWithString:[colorStr substringFromIndex:1]] scanHexInt:&rgb];
        msg.usernameColor = [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                                           green:((rgb >>  8) & 0xFF) / 255.0
                                            blue:( rgb        & 0xFF) / 255.0
                                           alpha:1.0];
    } else {
        // Couleur par défaut : violet 7TV
        msg.usernameColor = [UIColor colorWithRed:0.557 green:0.271 blue:0.878 alpha:1.0];
    }

    // ── 3. Extraire le texte du message ───────────────────────────────────────
    // Tout ce qui vient après " PRIVMSG #channel :"
    NSRange privmsgRange = [ircLine rangeOfString:@" PRIVMSG "];
    if (privmsgRange.location == NSNotFound) return nil;

    NSString *afterPrivmsg = [ircLine substringFromIndex:privmsgRange.location + privmsgRange.length];
    NSRange colonInMsg = [afterPrivmsg rangeOfString:@":"];
    if (colonInMsg.location == NSNotFound) return nil;

    NSString *rawText = [[afterPrivmsg substringFromIndex:colonInMsg.location + 1]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!rawText.length) return nil;

    // ── 4. Construire les segments texte + emotes ─────────────────────────────
    // On split le texte mot par mot et on regarde si chaque mot est une emote 7TV
    NSArray<NSString *> *words = [rawText componentsSeparatedByString:@" "];
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    NSMutableArray<NSDictionary *> *segments = [NSMutableArray array];
    NSMutableString *textBuffer = [NSMutableString string];

    for (NSString *word in words) {
        SevenTVEmote *emote = [mgr emoteForName:word];
        if (emote) {
            // Vider le buffer texte si nécessaire
            if (textBuffer.length > 0) {
                [segments addObject:@{
                    @"type":  @"text",
                    @"value": [textBuffer copy]
                }];
                [textBuffer setString:@""];
            }
            // Ajouter le segment emote
            NSMutableDictionary *emoteSeg = [NSMutableDictionary dictionary];
            emoteSeg[@"type"]     = @"emote";
            emoteSeg[@"value"]    = emote.emoteName;
            emoteSeg[@"emoteID"]  = emote.emoteID;
            emoteSeg[@"animated"] = @(emote.isAnimated);
            if (emote.width > 0 && emote.height > 0) {
                emoteSeg[@"width"]  = @(emote.width);
                emoteSeg[@"height"] = @(emote.height);
            }
            [segments addObject:[emoteSeg copy]];
        } else {
            // Texte normal
            if (textBuffer.length > 0) [textBuffer appendString:@" "];
            [textBuffer appendString:word];
        }
    }

    // Vider le buffer texte restant
    if (textBuffer.length > 0) {
        [segments addObject:@{
            @"type":  @"text",
            @"value": [textBuffer copy]
        }];
    }

    msg.segments = [segments copy];

    // ── 5. Parser les badges depuis le tag IRC badges= ────────────────────────
    // Format: badges=broadcaster/1,subscriber/0,premium/1
    // Chaque entrée = "badgeName/badgeVersion"
    NSString *badgesTag = tags[@"badges"];
    if (badgesTag.length > 0) {
        NSMutableArray<NSDictionary *> *badges = [NSMutableArray array];
        for (NSString *entry in [badgesTag componentsSeparatedByString:@","]) {
            if (!entry.length) continue;
            NSArray<NSString *> *parts = [entry componentsSeparatedByString:@"/"];
            NSString *name    = parts.firstObject;
            NSString *version = parts.count > 1 ? parts[1] : @"1";
            if (name.length > 0) {
                [badges addObject:@{@"name": name, @"version": version}];
            }
        }
        msg.badges = [badges copy];
    } else {
        msg.badges = @[];
    }

    return msg;
}

@end
