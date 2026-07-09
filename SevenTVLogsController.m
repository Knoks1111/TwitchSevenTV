/*
 * SevenTVLogsController.m
 *
 * Viewer de logs in-app pour TwitchSevenTV.
 * Utilise S7TVLogsDidUpdateNotification pour se rafraîchir sans polling.
 */

#import "SevenTVLogsController.h"
#import "SevenTVManager.h"

// Nombre de lignes à partir duquel on n'auto-scroll plus
// (pour ne pas interrompre l'utilisateur qui lit les anciens logs)
static const NSInteger kAutoScrollThreshold = 20;

@interface SevenTVLogsController ()

// ── UI ──
@property (nonatomic, strong) UITextView   *textView;
@property (nonatomic, strong) UILabel      *countLabel;   // "42 lignes"
@property (nonatomic, strong) UILabel      *emptyLabel;   // Placeholder quand vide

// ── État ──
// Contenu actuel du textView (on garde une NSMutableString
// pour éviter de reconstruire depuis le tableau à chaque update)
@property (nonatomic, strong) NSMutableString *currentText;
// Nombre de lignes déjà affichées (pour n'appender que les nouvelles)
@property (nonatomic, assign) NSInteger displayedLineCount;

@end


@implementation SevenTVLogsController

// ============================================================
// MARK: - Cycle de vie
// ============================================================

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Logs 7TV";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.currentText = [NSMutableString string];
    self.displayedLineCount = 0;

    [self setupNavigationBar];
    [self setupTextView];
    [self setupEmptyLabel];
    [self setupToolbar];

    // Charger les logs déjà en buffer
    [self reloadAllLogs];

    // S'abonner aux nouvelles lignes
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(logsDidUpdate:)
               name:S7TVLogsDidUpdateNotification
             object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Resync au cas où des logs seraient arrivés pendant qu'on était ailleurs
    [self reloadAllLogs];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


// ============================================================
// MARK: - Setup UI
// ============================================================

- (void)setupNavigationBar {
    // Bouton fermer (si présenté en modal)
    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeTapped)];
    self.navigationItem.rightBarButtonItem = closeBtn;

    // Label compteur de lignes (dans le titre de nav)
    self.countLabel = [[UILabel alloc] init];
    self.countLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.countLabel.textColor = [UIColor secondaryLabelColor];
    self.countLabel.textAlignment = NSTextAlignmentCenter;
    [self updateCountLabel:0];
    self.navigationItem.titleView = ({
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
            ({
                UILabel *title = [[UILabel alloc] init];
                title.text = @"Logs 7TV";
                title.font = [UIFont boldSystemFontOfSize:17];
                title;
            }),
            self.countLabel
        ]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 0;
        stack;
    });
}

- (void)setupTextView {
    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.selectable = YES;  // Pour que l'utilisateur puisse sélectionner du texte
    self.textView.scrollEnabled = YES;
    self.textView.backgroundColor = [UIColor systemBackgroundColor];

    // Police monospace pour aligner les timestamps
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.textColor = [UIColor labelColor];

    // Insets pour ne pas coller aux bords
    self.textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);

    [self.view addSubview:self.textView];

    // Contraintes — on laisse de la place en bas pour la toolbar
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        // La bottom constraint sera ajustée pour laisser la place à la toolbar
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                                   constant:-44.0],
    ]];
}

- (void)setupEmptyLabel {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.text = @"Aucun log pour l'instant.\nLes messages apparaîtront ici en temps réel.";
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.textColor = [UIColor tertiaryLabelColor];

    [self.view addSubview:self.emptyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

- (void)setupToolbar {
    // Barre d'actions en bas (au-dessus de la safe area)
    UIView *toolbar = [[UIView alloc] init];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.backgroundColor = [UIColor secondarySystemBackgroundColor];

    // Séparateur en haut de la toolbar
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [toolbar addSubview:separator];

    [NSLayoutConstraint activateConstraints:@[
        [separator.topAnchor constraintEqualToAnchor:toolbar.topAnchor],
        [separator.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5],
    ]];

    // Bouton "Copier tout"
    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyBtn setTitle:@"Copier tout" forState:UIControlStateNormal];
    [copyBtn setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [copyBtn addTarget:self action:@selector(copyAllTapped) forControlEvents:UIControlEventTouchUpInside];
    copyBtn.translatesAutoresizingMaskIntoConstraints = NO;

    // Bouton "Effacer"
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [clearBtn setTitle:@"Effacer" forState:UIControlStateNormal];
    [clearBtn setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
    [clearBtn setTintColor:[UIColor systemRedColor]];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [clearBtn addTarget:self action:@selector(clearTapped) forControlEvents:UIControlEventTouchUpInside];
    clearBtn.translatesAutoresizingMaskIntoConstraints = NO;

    // Stack horizontal pour les boutons
    UIStackView *btnStack = [[UIStackView alloc] initWithArrangedSubviews:@[copyBtn, clearBtn]];
    btnStack.translatesAutoresizingMaskIntoConstraints = NO;
    btnStack.axis = UILayoutConstraintAxisHorizontal;
    btnStack.distribution = UIStackViewDistributionFillEqually;
    btnStack.alignment = UIStackViewAlignmentCenter;

    [toolbar addSubview:btnStack];
    [NSLayoutConstraint activateConstraints:@[
        [btnStack.topAnchor constraintEqualToAnchor:toolbar.topAnchor constant:0.5],
        [btnStack.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor],
        [btnStack.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor],
        [btnStack.bottomAnchor constraintEqualToAnchor:toolbar.bottomAnchor],
    ]];

    [self.view addSubview:toolbar];
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [toolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [toolbar.heightAnchor constraintEqualToConstant:44.0],
    ]];
}


// ============================================================
// MARK: - Chargement des logs
// ============================================================

// Charge (ou recharge) tout le buffer depuis zéro.
// Utilisé à l'ouverture de l'écran et après un "Effacer".
- (void)reloadAllLogs {
    NSArray<NSString *> *allLogs = [[SevenTVManager sharedManager] allLogs];

    [self.currentText setString:@""];
    for (NSString *line in allLogs) {
        [self.currentText appendString:line];
        [self.currentText appendString:@"\n"];
    }

    self.textView.text = self.currentText;
    self.displayedLineCount = (NSInteger)allLogs.count;

    [self updateCountLabel:self.displayedLineCount];
    [self updateEmptyState:allLogs.count == 0];
    [self scrollToBottom:NO]; // Pas d'animation au chargement initial
}

// Appelé par la notification: ajoute uniquement les nouvelles lignes.
- (void)logsDidUpdate:(NSNotification *)notification {
    // Si le buffer a été effacé
    if (notification.userInfo[@"cleared"]) {
        [self reloadAllLogs];
        return;
    }

    // Sinon on append seulement les lignes qu'on n'a pas encore
    NSArray<NSString *> *allLogs = [[SevenTVManager sharedManager] allLogs];
    NSInteger total = (NSInteger)allLogs.count;

    if (total <= self.displayedLineCount) return; // Rien de neuf

    // Lignes nouvelles
    NSArray *newLines = [allLogs subarrayWithRange:
                         NSMakeRange(self.displayedLineCount,
                                     total - self.displayedLineCount)];

    for (NSString *line in newLines) {
        [self.currentText appendString:line];
        [self.currentText appendString:@"\n"];
    }

    self.textView.text = self.currentText;
    self.displayedLineCount = total;

    [self updateCountLabel:total];
    [self updateEmptyState:NO];

    // Auto-scroll seulement si l'utilisateur était déjà en bas
    // (ou s'il n'y a pas encore beaucoup de lignes)
    if (total <= kAutoScrollThreshold || [self isScrolledToBottom]) {
        [self scrollToBottom:YES];
    }
}


// ============================================================
// MARK: - Actions boutons
// ============================================================

- (void)copyAllTapped {
    NSString *text = self.textView.text;
    if (text.length == 0) {
        [self showToast:@"Aucun log à copier"];
        return;
    }

    [UIPasteboard generalPasteboard].string = text;
    [self showToast:@"✅ Logs copiés !"];
}

- (void)clearTapped {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Effacer les logs ?"
                         message:@"Toutes les lignes seront supprimées du buffer."
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Effacer"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *a) {
        [[SevenTVManager sharedManager] clearLogs];
        // reloadAllLogs sera appelé via la notification "cleared"
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)closeTapped {
    // Si on est dans la menuWindow (modal depuis bouton flottant 7TV),
    // il faut dismisser TOUTE la stack modale (nav + logs) et poster S7TVMenuDidDismiss
    // pour que SevenTVManager libère la menuWindow.
    // Sans ça, menuWindow reste en vie, capturant tous les touchers → freeze UI.
    UIViewController *root = self.navigationController ?: self;
    UIViewController *presenting = root.presentingViewController;

    if (presenting) {
        // On est dans un modal → dismiss toute la stack + notifier le manager
        [presenting dismissViewControllerAnimated:YES completion:^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"S7TVMenuDidDismiss" object:nil];
        }];
    } else {
        // On est pushé dans une nav sans modal (ex: depuis les settings Twitch natifs)
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}


// ============================================================
// MARK: - Helpers UI
// ============================================================

- (void)updateCountLabel:(NSInteger)count {
    if (count == 0) {
        self.countLabel.text = @"buffer vide";
    } else if (count == 1) {
        self.countLabel.text = @"1 ligne";
    } else {
        self.countLabel.text = [NSString stringWithFormat:@"%ld lignes", (long)count];
    }
}

- (void)updateEmptyState:(BOOL)isEmpty {
    self.emptyLabel.hidden  = !isEmpty;
    self.textView.hidden    = isEmpty;
}

- (BOOL)isScrolledToBottom {
    CGFloat contentHeight  = self.textView.contentSize.height;
    CGFloat scrollViewHeight = self.textView.bounds.size.height;
    CGFloat offset = self.textView.contentOffset.y;
    // Considère "en bas" si on est à moins de 100pt de la fin
    return (contentHeight - offset - scrollViewHeight) < 100.0;
}

- (void)scrollToBottom:(BOOL)animated {
    CGFloat contentHeight = self.textView.contentSize.height;
    CGFloat scrollHeight  = self.textView.bounds.size.height;
    if (contentHeight > scrollHeight) {
        CGPoint offset = CGPointMake(0, contentHeight - scrollHeight);
        [self.textView setContentOffset:offset animated:animated];
    }
}

// Toast léger (pas d'UIAlertController pour les feedbacks rapides)
- (void)showToast:(NSString *)message {
    UILabel *toast = [[UILabel alloc] init];
    toast.text = message;
    toast.textAlignment = NSTextAlignmentCenter;
    toast.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
    toast.textColor = [UIColor whiteColor];
    toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    toast.layer.cornerRadius = 10;
    toast.clipsToBounds = YES;
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.alpha = 0;

    [self.view addSubview:toast];
    [NSLayoutConstraint activateConstraints:@[
        [toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [toast.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-60],
        [toast.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-40],
        [toast.heightAnchor constraintEqualToConstant:40],
    ]];

    // Ajouter du padding horizontal via contentInsets n'est pas dispo sur UILabel,
    // on utilise donc des espaces dans le texte
    toast.text = [NSString stringWithFormat:@"  %@  ", message];

    [UIView animateWithDuration:0.25 animations:^{
        toast.alpha = 1.0;
    } completion:^(BOOL done) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                toast.alpha = 0;
            } completion:^(BOOL d) {
                [toast removeFromSuperview];
            }];
        });
    }];
}

@end
