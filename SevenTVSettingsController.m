/*
 * SevenTVSettingsController.m
 *
 * Style : copie pixel-perfect du style Twitch natif (InsetGrouped).
 *   - Fond          : #0E0E10  (noir profond, identique à l'app Twitch)
 *   - Cellules      : #1F1F23  (gris foncé)
 *   - Angles        : UITableViewStyleInsetGrouped (natif iOS)
 *   - Header 7TV    : logo + "7TV SETTINGS" gris clair (comme les autres sections Twitch)
 *   - Séparateurs   : couleur Twitch #2A2A2E
 *   - Texte         : blanc / gris secondaire
 *   - Accent        : violet 7TV rgb(142, 69, 224)
 */

#import "SevenTVSettingsController.h"
#import "SevenTVManager.h"
#import "SevenTVLogsController.h"
#import "SevenTVLogo.h"

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Palette couleurs
// ─────────────────────────────────────────────────────────────────────────────

// Fond général de la tableView (noir profond Twitch)
static UIColor *S7TVBg(void) {
    return [UIColor colorWithRed:0.055 green:0.055 blue:0.063 alpha:1.0]; // #0E0E10
}

// Fond des cellules (gris foncé Twitch)
static UIColor *S7TVCellBg(void) {
    return [UIColor colorWithRed:0.122 green:0.122 blue:0.137 alpha:1.0]; // #1F1F23
}

// Violet 7TV / Twitch
static UIColor *S7TVAccent(void) {
    return [UIColor colorWithRed:0.557 green:0.271 blue:0.878 alpha:1.0]; // #8E45E0
}

// Gris secondaire (sous-titres, icônes)
static UIColor *S7TVGray(void) {
    return [UIColor colorWithWhite:0.55 alpha:1.0];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers UI
// ─────────────────────────────────────────────────────────────────────────────

// Icône SF Symbol 22×22 pts
static UIImageView *S7TVIcon(NSString *sfName, UIColor *tint) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    UIImage *img = [UIImage systemImageNamed:sfName withConfiguration:cfg];
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.tintColor = tint;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [iv.widthAnchor  constraintEqualToConstant:22],
        [iv.heightAnchor constraintEqualToConstant:22],
    ]];
    return iv;
}

// Cellule standard avec icône + titre + (optionnel) sous-titre + chevron
// Style taille police identique Twitch natif : titre 17pt Regular, sous-titre 12pt Regular gris
static UITableViewCell *S7TVNavCell(NSString *title,
                                     NSString *subtitle,
                                     NSString *sfName,
                                     UIColor  *iconTint) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.accessoryType   = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = S7TVCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.06];

    UIImageView *icon = S7TVIcon(sfName, iconTint);
    [cell.contentView addSubview:icon];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = title;
    // Twitch natif : 17pt Regular (même poids que les cellules Settings iOS)
    titleLbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    titleLbl.textColor = [UIColor whiteColor];
    titleLbl.numberOfLines = 1;
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;

    if (subtitle.length > 0) {
        UILabel *subLbl = [[UILabel alloc] init];
        subLbl.text = subtitle;
        // Sous-titre : 12pt Regular gris (identique Twitch)
        subLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        subLbl.textColor = S7TVGray();
        subLbl.numberOfLines = 1;
        subLbl.translatesAutoresizingMaskIntoConstraints = NO;

        // Stack vertical centré dans la cellule
        UIStackView *stack = [[UIStackView alloc]
            initWithArrangedSubviews:@[titleLbl, subLbl]];
        stack.axis      = UILayoutConstraintAxisVertical;
        stack.spacing   = 2;
        stack.alignment = UIStackViewAlignmentLeading;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor   constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor   constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [stack.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [stack.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            // Assure que le stack ne déborde pas verticalement
            [stack.topAnchor      constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor constant:8],
            [stack.bottomAnchor   constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        ]];
    } else {
        [cell.contentView addSubview:titleLbl];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor     constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor     constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [titleLbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [titleLbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            // CRITIQUE : top+bottom pour que le label ait une hauteur résolue
            [titleLbl.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [titleLbl.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        ]];
    }
    return cell;
}

// Cellule avec UISwitch
// Titre 17pt Regular (identique Twitch natif), switch violet 7TV
static UITableViewCell *S7TVSwitchCell(NSString *title,
                                        NSString *sfName,
                                        UIColor  *iconTint,
                                        BOOL      isOn,
                                        id        target,
                                        SEL       action) {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle  = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = S7TVCellBg();

    UIImageView *icon = S7TVIcon(sfName, iconTint);
    [cell.contentView addSubview:icon];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    // 17pt Regular = taille standard iOS Settings / Twitch natif
    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor whiteColor];
    lbl.numberOfLines = 1;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on          = isOn;
    sw.onTintColor = S7TVAccent();
    [sw addTarget:target action:action forControlEvents:UIControlEventValueChanged];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:sw];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],

        // CRITIQUE top+bottom : résout la hauteur du label et centre verticalement
        [lbl.leadingAnchor   constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [lbl.topAnchor       constraintEqualToAnchor:cell.contentView.topAnchor constant:13],
        [lbl.bottomAnchor    constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-13],

        [sw.leadingAnchor    constraintGreaterThanOrEqualToAnchor:lbl.trailingAnchor constant:12],
        [sw.trailingAnchor   constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [sw.centerYAnchor    constraintEqualToAnchor:cell.contentView.centerYAnchor],
    ]];
    return cell;
}

// Header de section style Twitch : logo (optionnel) + texte gris uppercase
// Identique visuellement au header "7TV SETTINGS" de la capture
static UIView *S7TVSectionHeader(NSString *title, BOOL withLogo) {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = [UIColor clearColor];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title.uppercaseString;
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor colorWithWhite:0.60 alpha:1.0];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];

    if (withLogo) {
        // Petit logo 7TV à gauche du texte, comme sur la capture
        NSData *d = [[NSData alloc]
            initWithBase64EncodedString:kS7TVLogoBase64
                                options:NSDataBase64DecodingIgnoreUnknownCharacters];
        UIImage *logoImg = d ? [UIImage imageWithData:d scale:2.0] : nil;

        if (logoImg) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:logoImg];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            [container addSubview:iv];

            [NSLayoutConstraint activateConstraints:@[
                [iv.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
                [iv.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-8],
                [iv.widthAnchor    constraintEqualToConstant:22],
                [iv.heightAnchor   constraintEqualToConstant:16],

                [lbl.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:6],
                [lbl.bottomAnchor  constraintEqualToAnchor:container.bottomAnchor constant:-8],
                [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
            ]];
            return container;
        }
    }

    // Header texte seul (sans logo)
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-8],
        [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
    ]];
    return container;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Méthode utilitaire commune pour styleTableView
// ─────────────────────────────────────────────────────────────────────────────

static void S7TVStyleTableView(UITableView *tv) {
    tv.backgroundColor   = S7TVBg();
    tv.separatorColor    = [UIColor colorWithRed:0.165 green:0.165 blue:0.180 alpha:1.0];
    tv.separatorInset    = UIEdgeInsetsMake(0, 52, 0, 0);
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVSettingsController  (Hub principal)
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, S7TVHomeRow) {
    S7TVHomeRowEmotes = 0,
    S7TVHomeRowStats,
    S7TVHomeRowDebug,
};

@implementation SevenTVSettingsController

- (instancetype)init {
    // InsetGrouped = angles arrondis natifs iOS, identique aux paramètres Twitch
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    S7TVStyleTableView(self.tableView);
    [self buildNavBar];
}

- (void)buildNavBar {
    // Titre nav bar : logo 7TV + "7TV"
    NSData *d = [[NSData alloc]
        initWithBase64EncodedString:kS7TVLogoBase64
                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    UIImage *logo = d ? [UIImage imageWithData:d scale:2.0] : nil;

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
        CGFloat w = 28 + 6 + [@"7TV" sizeWithAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightBold]
        }].width;
        tv.frame = CGRectMake(0, 0, w, 20);
        self.navigationItem.titleView = tv;
    } else {
        self.title = @"7TV Settings";
    }

    if (self.openedAsModal) {
        UIBarButtonItem *close = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                 target:self action:@selector(closeTapped)];
        self.navigationItem.rightBarButtonItem = close;
    }
}

- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }

// ── TableView ──

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 3 : 1;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 ? 60 : 54;
}

// Header section 0 : logo + "7TV SETTINGS" (identique capture)
// Header section 1 : vide (pas de titre au-dessus de "Recharger")
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return s == 0 ? 44 : 24;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    if (s == 0) return S7TVSectionHeader(@"7TV Settings", YES);
    return [[UIView alloc] init];
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return 8;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    // Section 1 : Recharger les emotes
    if (ip.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.accessoryType   = UITableViewCellAccessoryDisclosureIndicator;
        cell.backgroundColor = S7TVCellBg();
        cell.selectedBackgroundView = [[UIView alloc] init];
        cell.selectedBackgroundView.backgroundColor =
            [UIColor colorWithWhite:1.0 alpha:0.06];

        UIImageView *icon = S7TVIcon(@"arrow.clockwise",
                                      [UIColor colorWithWhite:0.75 alpha:1.0]);
        [cell.contentView addSubview:icon];

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = @"Recharger les emotes";
        lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        lbl.textColor = [UIColor whiteColor];
        lbl.numberOfLines = 1;
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:lbl];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [lbl.leadingAnchor   constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [lbl.trailingAnchor  constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            [lbl.topAnchor       constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [lbl.bottomAnchor    constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        ]];
        return cell;
    }

    // Section 0 : menu de navigation
    NSString *sfName, *title, *subtitle;
    UIColor *iconTint = [UIColor colorWithWhite:0.75 alpha:1.0];

    switch (ip.row) {
        case S7TVHomeRowEmotes:
            sfName   = @"face.smiling";
            title    = @"Emotes 7TV";
            subtitle = @"Animées, picker, bouton flottant";
            iconTint = S7TVAccent();
            break;
        case S7TVHomeRowStats:
            sfName   = @"chart.bar.fill";
            title    = @"Statistiques";
            subtitle = @"Emotes chargées, channel actif";
            break;
        case S7TVHomeRowDebug:
            sfName   = @"ant.fill";
            title    = @"Débogage";
            subtitle = @"Logs console et tap logger";
            break;
        default:
            return [[UITableViewCell alloc] init];
    }

    return S7TVNavCell(title, subtitle, sfName, iconTint);
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
    S7TVStyleTableView(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 1 : 3;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    return S7TVSectionHeader(s == 0 ? @"Général" : @"Affichage", NO);
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return 8;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    if (ip.section == 0) {
        return S7TVSwitchCell(@"Activer les emotes 7TV",
                              @"checkmark.seal.fill",
                              S7TVAccent(),
                              mgr.isEnabled,
                              self, @selector(toggleEnabled:));
    }
    switch (ip.row) {
        case 0: return S7TVSwitchCell(@"Emotes animées dans le chat",
                    @"wand.and.stars",
                    [UIColor colorWithWhite:0.75 alpha:1.0],
                    mgr.showAnimated,
                    self, @selector(toggleAnimated:));
        case 1: return S7TVSwitchCell(@"Animations dans le picker",
                    @"photo.stack",
                    [UIColor colorWithWhite:0.75 alpha:1.0],
                    mgr.showPickerAnimations,
                    self, @selector(togglePickerAnimations:));
        case 2: return S7TVSwitchCell(@"Bouton flottant 7TV",
                    @"circle.grid.2x1.fill",
                    [UIColor colorWithWhite:0.75 alpha:1.0],
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
    S7TVStyleTableView(self.tableView);
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

- (void)refresh { [self.tableView reloadData]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 2; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 1 : 3;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 ? 64 : 52;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    return S7TVSectionHeader(s == 0 ? @"Channel actif" : @"Emotes chargées", NO);
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return 8;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    NSUInteger g = mgr.globalEmotes.count;
    NSUInteger c = mgr.channelEmotes.count;

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = S7TVCellBg();
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = S7TVGray();
    cell.detailTextLabel.numberOfLines = 0;

    if (ip.section == 0) {
        UIImageView *icon = S7TVIcon(@"tv.fill", [UIColor colorWithWhite:0.65 alpha:1.0]);
        [cell.contentView addSubview:icon];

        UILabel *titleLbl = [[UILabel alloc] init];
        titleLbl.text = mgr.currentChannelName ?: @"Aucun channel";
        titleLbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        titleLbl.textColor = [UIColor whiteColor];
        titleLbl.numberOfLines = 1;
        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *subLbl = [[UILabel alloc] init];
        subLbl.text = mgr.currentChannelTwitchID
            ? [NSString stringWithFormat:@"ID : %@", mgr.currentChannelTwitchID]
            : @"Rejoins un stream pour charger les emotes";
        subLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        subLbl.textColor = S7TVGray();
        subLbl.numberOfLines = 1;
        subLbl.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLbl, subLbl]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 3;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [stack.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        ]];
        return cell;
    }

    NSString *sfName, *label;
    NSUInteger count = 0;
    UIColor *valColor = [UIColor whiteColor];

    switch (ip.row) {
        case 0: sfName = @"globe";         label = @"Emotes globales";   count = g; break;
        case 1: sfName = @"person.2.fill"; label = @"Emotes du channel"; count = c; valColor = S7TVAccent(); break;
        case 2: sfName = @"sum";           label = @"Total";              count = g + c; break;
        default: return cell;
    }

    UIImageView *icon = S7TVIcon(sfName, [UIColor colorWithWhite:0.65 alpha:1.0]);
    [cell.contentView addSubview:icon];

    UILabel *nameLbl = [[UILabel alloc] init];
    nameLbl.text = label;
    nameLbl.font = ip.row == 2
        ? [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
        : [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    nameLbl.textColor = [UIColor whiteColor];
    nameLbl.numberOfLines = 1;
    nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:nameLbl];

    UILabel *valLbl = [[UILabel alloc] init];
    valLbl.text = [NSString stringWithFormat:@"%lu", (unsigned long)count];
    valLbl.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:
        ip.row == 2 ? UIFontWeightBold : UIFontWeightRegular];
    valLbl.textColor = valColor;
    valLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:valLbl];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor    constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor    constraintEqualToAnchor:cell.contentView.centerYAnchor],
        // CRITIQUE : top+bottom pour résoudre la hauteur du label
        [nameLbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [nameLbl.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [nameLbl.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        [valLbl.trailingAnchor  constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [valLbl.centerYAnchor   constraintEqualToAnchor:cell.contentView.centerYAnchor],
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
    S7TVStyleTableView(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) { case 0: return 2; case 1: return 1; case 2: return 1; default: return 0; }
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return S7TVSectionHeader(@"Options", NO);
        case 1: return S7TVSectionHeader(@"Logs",    NO);
        case 2: return S7TVSectionHeader(@"Danger",  NO);
        default: return [[UIView alloc] init];
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return 8;
}

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor clearColor];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    if (ip.section == 0) {
        switch (ip.row) {
            case 0: return S7TVSwitchCell(@"Logs console (Console.app)",
                        @"terminal.fill",
                        [UIColor colorWithWhite:0.75 alpha:1.0],
                        mgr.debugLogging,
                        self, @selector(toggleDebug:));
            case 1: return S7TVSwitchCell(@"Tap logger",
                        @"hand.tap.fill",
                        [UIColor colorWithWhite:0.75 alpha:1.0],
                        mgr.tapLogging,
                        self, @selector(toggleTapLog:));
        }
    }

    if (ip.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.accessoryType   = UITableViewCellAccessoryDisclosureIndicator;
        cell.backgroundColor = S7TVCellBg();
        cell.selectedBackgroundView = [[UIView alloc] init];
        cell.selectedBackgroundView.backgroundColor =
            [UIColor colorWithWhite:1.0 alpha:0.06];

        UIImageView *icon = S7TVIcon(@"doc.text.magnifyingglass",
                                      [UIColor colorWithWhite:0.75 alpha:1.0]);
        [cell.contentView addSubview:icon];

        UILabel *nameLbl = [[UILabel alloc] init];
        nameLbl.text = @"Voir les logs";
        nameLbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        nameLbl.textColor = [UIColor whiteColor];
        nameLbl.numberOfLines = 1;
        nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:nameLbl];

        NSUInteger n = [mgr allLogs].count;
        UILabel *badge = [[UILabel alloc] init];
        badge.text = [NSString stringWithFormat:@"%lu", (unsigned long)n];
        badge.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
        badge.textColor = S7TVGray();
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:badge];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor    constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor    constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [nameLbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
            // CRITIQUE : top+bottom pour que nameLbl soit visible
            [nameLbl.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
            [nameLbl.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
            [nameLbl.trailingAnchor constraintLessThanOrEqualToAnchor:badge.leadingAnchor constant:-8],
            [badge.trailingAnchor   constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            [badge.centerYAnchor    constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
        return cell;
    }

    // Section 2 : Effacer les logs
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = S7TVCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor =
        [UIColor colorWithWhite:1.0 alpha:0.06];

    UIImageView *icon = S7TVIcon(@"trash.fill", [UIColor systemRedColor]);
    [cell.contentView addSubview:icon];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = @"Effacer tous les logs";
    lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor systemRedColor];
    lbl.numberOfLines = 1;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [lbl.leadingAnchor   constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [lbl.trailingAnchor  constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [lbl.topAnchor       constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [lbl.bottomAnchor    constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
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
