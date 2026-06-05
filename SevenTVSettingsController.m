/*
 * SevenTVSettingsController.m
 *
 * Architecture : page d'accueil + sous-pages indépendantes (push navigation).
 * Chaque section → nouvelle page, pas d'accordéon.
 *
 * Pages :
 *   SevenTVSettingsController      → Hub principal (menu)
 *   SevenTVEmotesPageController    → Réglages des emotes
 *   SevenTVStatsPageController     → Statistiques en temps réel
 *   SevenTVDebugPageController     → Logs & débogage
 */

#import "SevenTVSettingsController.h"
#import "SevenTVManager.h"
#import "SevenTVLogsController.h"
#import "SevenTVLogo.h"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers visuels partagés
// ─────────────────────────────────────────────────────────────────────────────

static UIColor *S7TVAccent(void) {
    return [UIColor colorWithRed:0.557 green:0.271 blue:0.878 alpha:1.0]; // violet 7TV
}

static UIColor *S7TVAccentSoft(void) {
    return [UIColor colorWithRed:0.557 green:0.271 blue:0.878 alpha:0.12];
}

// Crée une UIImage SF Symbol colorée dans un carré arrondi (style iOS 16+)
static UIImageView *S7TVIconView(NSString *sfName, UIColor *tint, UIColor *bg) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
    UIImage *img = [UIImage systemImageNamed:sfName withConfiguration:cfg];

    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.tintColor = tint;
    iv.backgroundColor = bg;
    iv.layer.cornerRadius = 7;
    iv.contentMode = UIViewContentModeCenter;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [iv.widthAnchor  constraintEqualToConstant:30],
        [iv.heightAnchor constraintEqualToConstant:30],
    ]];
    return iv;
}

// Fabrique une cellule Switch réutilisable
static UITableViewCell *S7TVSwitchCell(NSString *title, NSString *sfIcon,
                                        UIColor *iconTint, UIColor *iconBg,
                                        BOOL isOn, id target, SEL action) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UIImageView *icon = S7TVIconView(sfIcon, iconTint, iconBg);
    [cell.contentView addSubview:icon];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = isOn;
    sw.onTintColor = S7TVAccent();
    [sw addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [lbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [lbl.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [lbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-80],
    ]];
    return cell;
}

// Header de section avec style 7TV
static UIView *S7TVSectionHeader(NSString *title) {
    UIView *v = [[UIView alloc] init];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title.uppercaseString;
    lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    lbl.textColor = [UIColor secondaryLabelColor];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor  constant:20],
        [lbl.bottomAnchor   constraintEqualToAnchor:v.bottomAnchor   constant:-6],
        [lbl.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-20],
    ]];
    return v;
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVSettingsController  (page d'accueil / hub)
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, S7TVHomeRow) {
    S7TVHomeRowEmotes = 0,
    S7TVHomeRowStats,
    S7TVHomeRowDebug,
    S7TVHomeRowReload,
    S7TVHomeRowCount
};

@implementation SevenTVSettingsController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildNavBar];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 58, 0, 0);
}

// ── Nav bar ──────────────────────────────────────────────────────────────────

- (void)buildNavBar {
    // Logo + titre
    NSData *logoData = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *logo = logoData ? [UIImage imageWithData:logoData scale:2.0] : nil;

    if (logo) {
        UIView *tv = [[UIView alloc] init];
        UIImageView *iv = [[UIImageView alloc] initWithImage:logo];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = @"7TV";
        lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
        lbl.textColor = S7TVAccent();
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [tv addSubview:iv]; [tv addSubview:lbl];
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor  constraintEqualToAnchor:tv.leadingAnchor],
            [iv.centerYAnchor  constraintEqualToAnchor:tv.centerYAnchor],
            [iv.widthAnchor    constraintEqualToConstant:28],
            [iv.heightAnchor   constraintEqualToConstant:20],
            [lbl.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
            [lbl.centerYAnchor constraintEqualToAnchor:tv.centerYAnchor],
            [lbl.trailingAnchor constraintEqualToAnchor:tv.trailingAnchor],
        ]];
        [tv sizeToFit];
        CGFloat w = 28 + 6 + lbl.intrinsicContentSize.width;
        tv.frame = CGRectMake(0, 0, w, MAX(20, lbl.intrinsicContentSize.height));
        self.navigationItem.titleView = tv;
    } else {
        self.title = @"7TV";
    }

    if (self.openedAsModal) {
        UIBarButtonItem *close = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                 target:self action:@selector(closeTapped)];
        self.navigationItem.rightBarButtonItem = close;
    }
}

- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }

// ── Table ────────────────────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 3 : 1; // section 0: 3 pages | section 1: reload
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 56;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return s == 0 ? 36 : 8;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    return s == 0 ? S7TVSectionHeader(@"Paramètres") : [[UIView alloc] init];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (ip.section == 1) {
        // Bouton Recharger
        UIImageView *icon = S7TVIconView(@"arrow.clockwise",
            [UIColor systemGreenColor],
            [[UIColor systemGreenColor] colorWithAlphaComponent:0.12]);
        [cell.contentView addSubview:icon];
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = @"Recharger les emotes";
        lbl.font = [UIFont systemFontOfSize:15];
        lbl.textColor = [UIColor systemGreenColor];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:lbl];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [lbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:12],
            [lbl.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
        return cell;
    }

    // Section 0 : menu principal
    NSString *sfName, *title, *subtitle;
    UIColor *iconTint, *iconBg;

    switch (ip.row) {
        case S7TVHomeRowEmotes:
            sfName   = @"face.smiling";
            title    = @"Emotes 7TV";
            subtitle = @"Animées, picker, bouton flottant";
            iconTint = S7TVAccent();
            iconBg   = S7TVAccentSoft();
            break;
        case S7TVHomeRowStats:
            sfName   = @"chart.bar.fill";
            title    = @"Statistiques";
            subtitle = @"Emotes chargées, channel actif";
            iconTint = [UIColor systemBlueColor];
            iconBg   = [[UIColor systemBlueColor] colorWithAlphaComponent:0.12];
            break;
        case S7TVHomeRowDebug:
            sfName   = @"ant.fill";
            title    = @"Débogage";
            subtitle = @"Logs console et tap logger";
            iconTint = [UIColor systemOrangeColor];
            iconBg   = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.12];
            break;
        default:
            return cell;
    }

    UIImageView *icon = S7TVIconView(sfName, iconTint, iconBg);
    [cell.contentView addSubview:icon];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = title;
    titleLbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *subLbl = [[UILabel alloc] init];
    subLbl.text = subtitle;
    subLbl.font = [UIFont systemFontOfSize:12];
    subLbl.textColor = [UIColor secondaryLabelColor];
    subLbl.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLbl, subLbl]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [stack.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
    ]];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 1) { [self reloadEmotes]; return; }

    UIViewController *dest = nil;
    switch (ip.row) {
        case S7TVHomeRowEmotes: dest = [[SevenTVEmotesPageController alloc] init]; break;
        case S7TVHomeRowStats:  dest = [[SevenTVStatsPageController  alloc] init]; break;
        case S7TVHomeRowDebug:  dest = [[SevenTVDebugPageController  alloc] init]; break;
    }
    if (dest) [self.navigationController pushViewController:dest animated:YES];
}

- (void)reloadEmotes {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr loadGlobalEmotes];
    if (mgr.currentChannelTwitchID)
        [mgr loadEmotesForChannelTwitchID:mgr.currentChannelTwitchID];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Rechargement lancé"
                         message:@"Les emotes seront disponibles dans quelques secondes."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVEmotesPageController
// ─────────────────────────────────────────────────────────────────────────────

@implementation SevenTVEmotesPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Emotes 7TV";
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 58, 0, 0);

    // Badge "Version" en titre secondaire dans la nav bar
    UILabel *badge = [[UILabel alloc] init];
    badge.text = @"v3";
    badge.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    badge.textColor = [UIColor whiteColor];
    badge.backgroundColor = S7TVAccent();
    badge.textAlignment = NSTextAlignmentCenter;
    badge.layer.cornerRadius = 8;
    badge.clipsToBounds = YES;
    badge.frame = CGRectMake(0, 0, 32, 20);
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithCustomView:badge];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 1 : 3;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 52;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 36;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    return S7TVSectionHeader(s == 0 ? @"Général" : @"Affichage");
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    if (ip.section == 0) {
        return S7TVSwitchCell(@"Activer les emotes 7TV",
                              @"checkmark.seal.fill",
                              S7TVAccent(), S7TVAccentSoft(),
                              mgr.isEnabled,
                              self, @selector(toggleEnabled:));
    }

    switch (ip.row) {
        case 0: return S7TVSwitchCell(@"Emotes animées dans le chat",
                    @"wand.and.stars",
                    [UIColor systemPurpleColor],
                    [[UIColor systemPurpleColor] colorWithAlphaComponent:0.12],
                    mgr.showAnimated,
                    self, @selector(toggleAnimated:));
        case 1: return S7TVSwitchCell(@"Animations dans le picker",
                    @"photo.stack",
                    [UIColor systemIndigoColor],
                    [[UIColor systemIndigoColor] colorWithAlphaComponent:0.12],
                    mgr.showPickerAnimations,
                    self, @selector(togglePickerAnimations:));
        case 2: return S7TVSwitchCell(@"Bouton flottant 7TV",
                    @"circle.grid.2x1.fill",
                    [UIColor systemPinkColor],
                    [[UIColor systemPinkColor] colorWithAlphaComponent:0.12],
                    mgr.showFloatingButton,
                    self, @selector(toggleFloatingButton:));
        default: return [[UITableViewCell alloc] init];
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
}

- (void)toggleEnabled:(UISwitch *)sw          { [SevenTVManager sharedManager].isEnabled           = sw.isOn; }
- (void)toggleAnimated:(UISwitch *)sw         { [SevenTVManager sharedManager].showAnimated         = sw.isOn; }
- (void)togglePickerAnimations:(UISwitch *)sw { [SevenTVManager sharedManager].showPickerAnimations = sw.isOn; }
- (void)toggleFloatingButton:(UISwitch *)sw   { [SevenTVManager sharedManager].showFloatingButton   = sw.isOn; }

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVStatsPageController
// ─────────────────────────────────────────────────────────────────────────────

@interface SevenTVStatsPageController ()
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation SevenTVStatsPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Statistiques";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
        target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refresh {
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 1 : 3;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 ? 80 : 52;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 36;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    return S7TVSectionHeader(s == 0 ? @"Channel actif" : @"Emotes chargées");
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    NSUInteger g = mgr.globalEmotes.count;
    NSUInteger c = mgr.channelEmotes.count;

    if (ip.section == 0) {
        // Grande cellule channel
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UIImageView *icon = S7TVIconView(@"tv.fill",
            [UIColor systemBlueColor],
            [[UIColor systemBlueColor] colorWithAlphaComponent:0.12]);
        [cell.contentView addSubview:icon];

        UILabel *titleLbl = [[UILabel alloc] init];
        titleLbl.text = mgr.currentChannelName ?: @"Aucun channel";
        titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *subLbl = [[UILabel alloc] init];
        subLbl.text = mgr.currentChannelTwitchID
            ? [NSString stringWithFormat:@"ID Twitch : %@", mgr.currentChannelTwitchID]
            : @"Rejoins un stream pour charger les emotes";
        subLbl.font = [UIFont systemFontOfSize:12];
        subLbl.textColor = [UIColor secondaryLabelColor];
        subLbl.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLbl, subLbl]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 3;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
            [stack.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        ]];
        return cell;
    }

    // Section 1 : compteurs
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    NSString *sfName, *label, *value;
    UIColor *tint;
    NSUInteger count = 0;

    switch (ip.row) {
        case 0:
            sfName = @"globe";
            label  = @"Emotes globales";
            count  = g;
            tint   = [UIColor systemBlueColor];
            break;
        case 1:
            sfName = @"person.2.fill";
            label  = @"Emotes du channel";
            count  = c;
            tint   = S7TVAccent();
            break;
        case 2:
            sfName = @"sum";
            label  = @"Total";
            count  = g + c;
            tint   = [UIColor systemGreenColor];
            cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            break;
    }

    value = [NSString stringWithFormat:@"%lu", (unsigned long)count];

    UIImageView *icon = S7TVIconView(sfName, tint, [tint colorWithAlphaComponent:0.12]);
    [cell.contentView addSubview:icon];

    UILabel *nameLbl = [[UILabel alloc] init];
    nameLbl.text = label;
    nameLbl.font = ip.row == 2
        ? [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
        : [UIFont systemFontOfSize:15];
    nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:nameLbl];

    UILabel *valLbl = [[UILabel alloc] init];
    valLbl.text = value;
    valLbl.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:
        ip.row == 2 ? UIFontWeightBold : UIFontWeightRegular];
    valLbl.textColor = tint;
    valLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:valLbl];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor   constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor   constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [nameLbl.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [nameLbl.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [valLbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [valLbl.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
    ]];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVDebugPageController
// ─────────────────────────────────────────────────────────────────────────────

@implementation SevenTVDebugPageController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Débogage";
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 58, 0, 0);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case 0: return 2; // switches
        case 1: return 1; // voir les logs
        case 2: return 1; // effacer les logs
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 52;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 36;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return S7TVSectionHeader(@"Options");
        case 1: return S7TVSectionHeader(@"Logs");
        case 2: return S7TVSectionHeader(@"Danger");
        default: return [[UIView alloc] init];
    }
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    if (ip.section == 0) {
        switch (ip.row) {
            case 0: return S7TVSwitchCell(@"Logs console (Console.app)",
                        @"terminal.fill",
                        [UIColor systemOrangeColor],
                        [[UIColor systemOrangeColor] colorWithAlphaComponent:0.12],
                        mgr.debugLogging,
                        self, @selector(toggleDebug:));
            case 1: return S7TVSwitchCell(@"Tap logger",
                        @"hand.tap.fill",
                        [UIColor systemYellowColor],
                        [[UIColor systemYellowColor] colorWithAlphaComponent:0.12],
                        mgr.tapLogging,
                        self, @selector(toggleTapLog:));
        }
    }

    if (ip.section == 1) {
        // Cellule "Voir les logs" avec badge de comptage
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        UIImageView *icon = S7TVIconView(@"doc.text.magnifyingglass",
            [UIColor systemOrangeColor],
            [[UIColor systemOrangeColor] colorWithAlphaComponent:0.12]);
        [cell.contentView addSubview:icon];

        UILabel *nameLbl = [[UILabel alloc] init];
        nameLbl.text = @"Voir les logs";
        nameLbl.font = [UIFont systemFontOfSize:15];
        nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:nameLbl];

        NSUInteger n = [mgr allLogs].count;
        UILabel *badge = [[UILabel alloc] init];
        badge.text = [NSString stringWithFormat:@"%lu", (unsigned long)n];
        badge.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        badge.textColor = [UIColor secondaryLabelColor];
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:badge];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor   constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor   constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [nameLbl.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
            [nameLbl.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [badge.trailingAnchor  constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            [badge.centerYAnchor   constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
        return cell;
    }

    // Section 2 : effacer les logs
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIImageView *icon = S7TVIconView(@"trash.fill",
        [UIColor systemRedColor],
        [[UIColor systemRedColor] colorWithAlphaComponent:0.12]);
    [cell.contentView addSubview:icon];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = @"Effacer tous les logs";
    lbl.font = [UIFont systemFontOfSize:15];
    lbl.textColor = [UIColor systemRedColor];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [lbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [lbl.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
    ]];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == 1 && ip.row == 0) {
        [self.navigationController
            pushViewController:[[SevenTVLogsController alloc] init] animated:YES];
        return;
    }

    if (ip.section == 2 && ip.row == 0) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Effacer les logs"
                             message:@"Cette action est irréversible."
                      preferredStyle:UIAlertControllerStyleActionSheet];
        [alert addAction:[UIAlertAction actionWithTitle:@"Effacer"
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
                [[SevenTVManager sharedManager] clearLogs];
                [tv reloadData];
            }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Annuler"
            style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)toggleDebug:(UISwitch *)sw  { [SevenTVManager sharedManager].debugLogging = sw.isOn; }
- (void)toggleTapLog:(UISwitch *)sw { [SevenTVManager sharedManager].tapLogging   = sw.isOn; }

@end
