/*
 * SevenTVChatOverlayView.m
 */

#import "SevenTVChatOverlayView.h"
#import "SevenTVChatCell.h"
#import "SevenTVManager.h"

static const NSUInteger kMaxMessages = 200;

@interface SevenTVChatOverlayView () <UITableViewDataSource, UITableViewDelegate, UIScrollViewDelegate>

@property (nonatomic, strong) UITableView                    *tableView;
@property (nonatomic, strong) NSMutableArray<SevenTVChatMessage *> *messages;
@property (nonatomic, assign) BOOL                            autoScroll; // YES = suit le bas

@end

@implementation SevenTVChatOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        _messages   = [NSMutableArray array];
        _autoScroll = YES;

        [self buildTableView];
        [self observeNotifications];
    }
    return self;
}

- (void)buildTableView {
    UITableView *tv = [[UITableView alloc] initWithFrame:self.bounds style:UITableViewStylePlain];
    tv.dataSource             = self;
    tv.delegate               = self;
    tv.backgroundColor        = [UIColor clearColor];
    tv.separatorStyle         = UITableViewCellSeparatorStyleNone;
    tv.rowHeight              = UITableViewAutomaticDimension;
    tv.estimatedRowHeight     = 36;
    tv.showsVerticalScrollIndicator = NO;
    tv.autoresizingMask       = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.contentInset           = UIEdgeInsetsMake(0, 0, 8, 0);

    [tv registerClass:[SevenTVChatCell class]
        forCellReuseIdentifier:kSevenTVChatCellReuseID];

    [self addSubview:tv];
    self.tableView = tv;
}

- (void)observeNotifications {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // Nouveau message IRC
    [nc addObserver:self
           selector:@selector(handleNewMessage:)
               name:@"S7TVNewChatMessage"
             object:nil];

    // CLEARCHAT (ban/timeout) → supprimer tous les messages d'un user
    [nc addObserver:self
           selector:@selector(handleClearUser:)
               name:@"S7TVChatClear"
             object:nil];

    // CLEARMSG → supprimer un message par ID
    [nc addObserver:self
           selector:@selector(handleDeleteMessage:)
               name:@"S7TVChatDeleteMessage"
             object:nil];

    // Badges chargés (hardcodés + API Twitch) → recharger UNIQUEMENT les cellules
    // visibles. Évite de reconstruire les NSAttributedString de toutes les 200 cellules
    // d'un coup, ce qui bloque le main thread plusieurs secondes.
    [nc addObserver:self
           selector:@selector(_badgesLoaded:)
               name:@"S7TVBadgesLoaded"
             object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// ────────────────────────────────────────────────────────────
// MARK: - API publique
// ────────────────────────────────────────────────────────────

- (void)addMessage:(SevenTVChatMessage *)message {
    // Appel direct si déjà sur le main thread (évite double-dispatch
    // qui peut désynchroniser numberOfRows vs cellForRow)
    if ([NSThread isMainThread]) {
        [self _addMessageOnMain:message];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _addMessageOnMain:message];
        });
    }
}

- (void)clearMessagesForUser:(NSString *)username {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *lower = username.lowercaseString;
        for (SevenTVChatMessage *m in self.messages) {
            if ([m.username.lowercaseString isEqualToString:lower]) {
                m.isDeleted = YES;
            }
        }
        [self.tableView reloadData];
    });
}

- (void)deleteMessageWithID:(NSString *)messageId {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (SevenTVChatMessage *m in self.messages) {
            if ([m.messageId isEqualToString:messageId]) {
                m.isDeleted = YES;
                break;
            }
        }
        [self.tableView reloadData];
    });
}

// ────────────────────────────────────────────────────────────
// MARK: - Handlers notifications
// ────────────────────────────────────────────────────────────

- (void)handleNewMessage:(NSNotification *)notif {
    SevenTVChatMessage *msg = notif.userInfo[@"message"];
    // Passer par addMessage: pour le guard de thread (notifications postées
    // depuis TweakSevenTV sont déjà sur main, mais on reste défensif)
    if (msg) [self addMessage:msg];
}

- (void)handleClearUser:(NSNotification *)notif {
    NSString *username = notif.userInfo[@"username"];
    if (username) [self clearMessagesForUser:username];
}

- (void)handleDeleteMessage:(NSNotification *)notif {
    NSString *msgId = notif.userInfo[@"messageId"];
    if (msgId) [self deleteMessageWithID:msgId];
}

// FIX — badges chargés : recharger UNIQUEMENT les cellules visibles.
// Avant : chaque cellule avait son propre observer et appelait configureWithMessage:
// → jusqu'à 200 NSAttributedString reconstruits simultanément → freeze principal.
// Maintenant : une seule source de vérité ici, reloadRowsAtIndexPaths: sur les
// cellules visibles seulement (typiquement 10–15 cellules à l'écran).
- (void)_badgesLoaded:(NSNotification *)n {
    NSArray<NSIndexPath *> *visible = [self.tableView indexPathsForVisibleRows];
    if (visible.count > 0) {
        [self.tableView reloadRowsAtIndexPaths:visible
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

// ────────────────────────────────────────────────────────────
// MARK: - Logique interne (main thread uniquement)
// ────────────────────────────────────────────────────────────

- (void)_addMessageOnMain:(SevenTVChatMessage *)message {
    // FIX — Trim + reloadData = freeze au-delà de 200 messages.
    //
    // AVANT : on retirait du tableau PUIS on comparait visibleRows vs newRow.
    // Comme la table n'avait pas encore été mise à jour, les deux valeurs
    // divergeaient systématiquement → reloadData sur CHAQUE nouveau message
    // dès que le buffer est plein → main thread bloqué en permanence.
    //
    // MAINTENANT :
    //   • Pas de trim → insertRows simple (chemin normal).
    //   • Trim (buffer plein) → batch beginUpdates/deleteRows+insertRows/endUpdates.
    //     La table reste synchronisée avec le tableau sans jamais faire reloadData.

    BOOL needsTrim = (self.messages.count >= kMaxMessages);

    if (needsTrim) {
        [self.messages removeObjectAtIndex:0];
    }
    [self.messages addObject:message];

    NSInteger newRow = (NSInteger)self.messages.count - 1;
    NSIndexPath *newIP = [NSIndexPath indexPathForRow:newRow inSection:0];

    if (needsTrim) {
        // Supprimer la première ligne (décalée) + insérer la nouvelle dernière ligne
        NSIndexPath *firstIP = [NSIndexPath indexPathForRow:0 inSection:0];
        [self.tableView beginUpdates];
        [self.tableView deleteRowsAtIndexPaths:@[firstIP]
                              withRowAnimation:UITableViewRowAnimationNone];
        [self.tableView insertRowsAtIndexPaths:@[newIP]
                              withRowAnimation:UITableViewRowAnimationNone];
        [self.tableView endUpdates];
    } else {
        NSInteger visibleRows = [self.tableView numberOfRowsInSection:0];
        if (visibleRows == newRow) {
            [self.tableView beginUpdates];
            [self.tableView insertRowsAtIndexPaths:@[newIP]
                                  withRowAnimation:UITableViewRowAnimationNone];
            [self.tableView endUpdates];
        } else {
            // Désynchronisation initiale (premier message, reloadData forcé externe, etc.)
            [self.tableView reloadData];
        }
    }

    if (self.autoScroll && self.messages.count > 0) {
        [self.tableView scrollToRowAtIndexPath:newIP
                              atScrollPosition:UITableViewScrollPositionBottom
                                      animated:NO];
    }
}

// ────────────────────────────────────────────────────────────
// MARK: - UITableViewDataSource
// ────────────────────────────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.messages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    SevenTVChatCell *cell = [tv dequeueReusableCellWithIdentifier:kSevenTVChatCellReuseID
                                                     forIndexPath:ip];
    // Guard out-of-bounds
    if (ip.row < 0 || (NSUInteger)ip.row >= self.messages.count) {
        [cell prepareForReuse]; // vide le contenu résiduel
        return cell;
    }
    SevenTVChatMessage *msg = self.messages[ip.row];
    [cell configureWithMessage:msg];
    return cell;
}

// ────────────────────────────────────────────────────────────
// MARK: - UIScrollViewDelegate (auto-scroll)
// ────────────────────────────────────────────────────────────

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    // L'utilisateur scroll manuellement → stopper l'auto-scroll
    self.autoScroll = NO;
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self _checkIfAtBottom:scrollView];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView
                   willDecelerate:(BOOL)decelerate {
    if (!decelerate) [self _checkIfAtBottom:scrollView];
}

- (void)_checkIfAtBottom:(UIScrollView *)sv {
    CGFloat maxOffset = sv.contentSize.height - sv.bounds.size.height + sv.contentInset.bottom;
    if (sv.contentOffset.y >= maxOffset - 20.0) {
        // L'utilisateur est revenu en bas → reprendre l'auto-scroll
        self.autoScroll = YES;
    }
}

@end
