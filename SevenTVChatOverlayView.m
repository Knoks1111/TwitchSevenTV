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

// ────────────────────────────────────────────────────────────
// MARK: - Logique interne (main thread uniquement)
// ────────────────────────────────────────────────────────────

- (void)_addMessageOnMain:(SevenTVChatMessage *)message {
    // Trimmer à 200 messages
    while (self.messages.count >= kMaxMessages) {
        [self.messages removeObjectAtIndex:0];
        // Après trim, la tableView est désynchronisée → on doit reloadData
        // mais on attend d'avoir ajouté le nouveau message d'abord
    }

    [self.messages addObject:message];

    NSInteger newRow     = (NSInteger)self.messages.count - 1;
    NSIndexPath *ip      = [NSIndexPath indexPathForRow:newRow inSection:0];
    NSInteger visibleRows = [self.tableView numberOfRowsInSection:0];

    if (visibleRows == newRow) {
        // Cas normal : insertRows (ne perturbe pas le scroll en cours)
        [self.tableView beginUpdates];
        [self.tableView insertRowsAtIndexPaths:@[ip]
                              withRowAnimation:UITableViewRowAnimationNone];
        [self.tableView endUpdates];
    } else {
        // Désynchronisation (trim, premier message, etc.) → reloadData
        [self.tableView reloadData];
    }

    if (self.autoScroll && self.messages.count > 0) {
        [self.tableView scrollToRowAtIndexPath:ip
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
