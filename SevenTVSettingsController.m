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
#import "SevenTVURLProtocol.h"
#import "SevenTVLogo.h"
#import "SevenTVAdBlock.h"

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

static UIColor *S7TVGreen(void)  { return [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]; }
static UIColor *S7TVOrange(void) { return [UIColor colorWithRed:1.00 green:0.58 blue:0.00 alpha:1.0]; }
static UIColor *S7TVRed(void)    { return [UIColor systemRedColor]; }

// Helper NSUserDefaults
static BOOL S7TVBool(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}
static void S7TVSetBool(NSString *key, BOOL val) {
    [[NSUserDefaults standardUserDefaults] setBool:val forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVSettingsController  (Hub principal)
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, S7TVHomeSection) {
    S7TVHomeSectionMain   = 0,
    S7TVHomeSectionProxy  = 1,
    S7TVHomeSectionLive   = 2,
    S7TVHomeSectionAds    = 3,
    S7TVHomeSectionURLs   = 4,
    S7TVHomeSectionReload = 5,
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

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"S7TVMenuDidDismiss" object:nil];
    }];
}

// ── TableView ──

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 6; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case S7TVHomeSectionMain:   return 3;
        case S7TVHomeSectionProxy:  return 1;
        case S7TVHomeSectionLive:   return 1;
        case S7TVHomeSectionAds:    return 1;
        case S7TVHomeSectionURLs:   return 2;
        case S7TVHomeSectionReload: return 1;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 60;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return s == S7TVHomeSectionMain ? 44 : 36;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case S7TVHomeSectionMain:   return S7TVSectionHeader(@"7TV Settings", YES);
        case S7TVHomeSectionProxy:  return S7TVSectionHeader(@"Stream Proxy", NO);
        case S7TVHomeSectionLive:   return S7TVSectionHeader(@"Live Stream Control", NO);
        case S7TVHomeSectionAds:    return S7TVSectionHeader(@"Disable Ads", NO);
        case S7TVHomeSectionURLs:   return S7TVSectionHeader(@"Filtering", NO);
        case S7TVHomeSectionReload: return [[UIView alloc] init];
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

    // Section Reload
    if (ip.section == S7TVHomeSectionReload) {
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

    // Section Main : Emotes / Stats / Debug
    if (ip.section == S7TVHomeSectionMain) {
        NSString *sfName, *title, *subtitle;
        UIColor *iconTint = [UIColor colorWithWhite:0.75 alpha:1.0];
        switch (ip.row) {
            case 0: sfName=@"face.smiling";   title=@"Emotes 7TV";   subtitle=@"Animées, picker"; iconTint=S7TVAccent(); break;
            case 1: sfName=@"chart.bar.fill"; title=@"Statistiques"; subtitle=@"Emotes chargées, channel actif"; break;
            case 2: sfName=@"ant.fill";       title=@"Débogage";     subtitle=@"Logs, tap logger, bouton flottant"; break;
            default: return [[UITableViewCell alloc] init];
        }
        return S7TVNavCell(title, subtitle, sfName, iconTint);
    }

    // Section Stream Proxy
    if (ip.section == S7TVHomeSectionProxy) {
        BOOL proxyOn = S7TVBool(kTCStreamProxyEnabled);
        return S7TVNavCell(@"Stream Proxy", proxyOn ? @"Activé" : @"Désactivé",
                           @"network", S7TVAccent());
    }

    // Section Live Stream Control
    if (ip.section == S7TVHomeSectionLive) {
        return S7TVNavCell(@"Live Stream Control", @"Auto collect, Ad indicator",
                           @"play.tv.fill", [UIColor colorWithWhite:0.75 alpha:1.0]);
    }

    // Section Disable Ads
    if (ip.section == S7TVHomeSectionAds) {
        BOOL adsOff = S7TVBool(kTCAdsDisabled);
        return S7TVNavCell(@"Disable Ads", adsOff ? @"Activé" : @"Désactivé",
                           @"hand.raised.slash.fill", [UIColor colorWithWhite:0.75 alpha:1.0]);
    }

    // Section Filtering : Blocked URLs / Excluded URLs
    if (ip.section == S7TVHomeSectionURLs) {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if (ip.row == 0) {
            NSArray *blocked = [ud arrayForKey:kTCBlockedURLList] ?: @[];
            NSString *sub = [NSString stringWithFormat:@"%lu règles", (unsigned long)blocked.count];
            return S7TVNavCell(@"Blocked URLs", sub, @"minus.circle.fill", S7TVRed());
        } else {
            NSArray *excluded = [ud arrayForKey:kTCExcludedURLList] ?: @[];
            NSString *sub = [NSString stringWithFormat:@"%lu entrées", (unsigned long)excluded.count];
            return S7TVNavCell(@"Excluded URLs", sub, @"eye.slash.fill",
                               [UIColor colorWithWhite:0.75 alpha:1.0]);
        }
    }

    return [[UITableViewCell alloc] init];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];

    if (ip.section == S7TVHomeSectionReload) { [self reloadEmotes]; return; }

    UIViewController *dest = nil;
    if (ip.section == S7TVHomeSectionMain) {
        switch (ip.row) {
            case 0: dest = [[SevenTVEmotesPageController alloc] init]; break;
            case 1: dest = [[SevenTVStatsPageController  alloc] init]; break;
            case 2: dest = [[SevenTVDebugPageController  alloc] init]; break;
        }
    } else if (ip.section == S7TVHomeSectionProxy) {
        dest = [[S7TVStreamProxyController alloc] init];
    } else if (ip.section == S7TVHomeSectionLive) {
        dest = [[S7TVLiveStreamController alloc] init];
    } else if (ip.section == S7TVHomeSectionAds) {
        dest = [[S7TVDisableAdsController alloc] init];
    } else if (ip.section == S7TVHomeSectionURLs) {
        dest = ip.row == 0
            ? (UITableViewController *)[[S7TVBlockedURLsController  alloc] init]
            : (UITableViewController *)[[S7TVExcludedURLsController alloc] init];
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
// MARK: - S7TVStreamProxyController
// ─────────────────────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, S7TVProxySection) {
    S7TVProxySectionStatus  = 0,
    S7TVProxySectionToggles = 1,
    S7TVProxySectionAddress = 2,
    S7TVProxySectionSaved   = 3,
    S7TVProxySectionLocal   = 4,
};

@interface S7TVStreamProxyController ()
@property (nonatomic, strong) NSTimer     *statusTimer;
@property (nonatomic, strong) UITextField *proxyField;
@end

@implementation S7TVStreamProxyController

- (instancetype)init { self = [super initWithStyle:UITableViewStyleInsetGrouped]; return self; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Stream Proxy";
    S7TVStyleTableView(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
        target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.statusTimer invalidate]; self.statusTimer = nil;
}
- (void)refreshStatus {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:S7TVProxySectionStatus]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 5; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case S7TVProxySectionStatus:  return 1;
        case S7TVProxySectionToggles: return 6;
        case S7TVProxySectionAddress: return 3;
        case S7TVProxySectionSaved:   return 1;
        case S7TVProxySectionLocal:   return 2;
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 44; }

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case S7TVProxySectionStatus:  return S7TVSectionHeader(@"Status", NO);
        case S7TVProxySectionToggles: return S7TVSectionHeader(@"Options", NO);
        case S7TVProxySectionAddress: return S7TVSectionHeader(@"Proxy Address", NO);
        case S7TVProxySectionSaved:   return S7TVSectionHeader(@"Saved Proxies", NO);
        case S7TVProxySectionLocal:   return S7TVSectionHeader(@"Local Proxy (Experimental)", NO);
        default: return [[UIView alloc] init];
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s { return s == S7TVProxySectionStatus || s == S7TVProxySectionAddress || s == S7TVProxySectionLocal ? UITableViewAutomaticDimension : 8; }

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    NSString *footer = nil;
    if (s == S7TVProxySectionStatus)
        footer = @"Green: connected. Orange: connecting. Red: timeout. IP shows what the app currently sees.";
    else if (s == S7TVProxySectionAddress)
        footer = @"Enter any HTTPS URL or host:port. Use $url for best compatibility across live, VOD, and clips. For loopback, enable Local Proxy below.";
    else if (s == S7TVProxySectionLocal)
        footer = @"Run a lightweight local proxy inside the app (loopback). Enable Stream Proxy to route through it.";
    if (!footer) { UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor]; return v; }
    UIView *container = [[UIView alloc] init];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = footer;
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    lbl.textColor = S7TVGray();
    lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
        [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [lbl.topAnchor      constraintEqualToAnchor:container.topAnchor constant:6],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-6],
    ]];
    return container;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == S7TVProxySectionAddress && ip.row == 0) return 56;
    return 52;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    // ── STATUS ──
    if (ip.section == S7TVProxySectionStatus) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = S7TVCellBg();
        UIView *dot = [[UIView alloc] init];
        dot.layer.cornerRadius = 5;
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        BOOL enabled      = S7TVBool(kTCStreamProxyEnabled);
        BOOL localEnabled = S7TVBool(kTCStreamProxyLocalEnabled);
        NSString *proxyURL = [ud stringForKey:kTCStreamProxyURL] ?: @"";
        UIColor *dotColor; NSString *statusText;
        if (!enabled)                              { dotColor = S7TVGray();   statusText = @"Status: Disabled"; }
        else if (!proxyURL.length && !localEnabled){ dotColor = S7TVRed();   statusText = @"Status: Missing Proxy"; }
        else                                       { dotColor = S7TVGreen(); statusText = @"Status: Connected"; }
        dot.backgroundColor = dotColor;
        UILabel *statusLbl = [[UILabel alloc] init];
        statusLbl.text = statusText;
        statusLbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        statusLbl.textColor = [UIColor whiteColor];
        statusLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:dot];
        [cell.contentView addSubview:statusLbl];
        [NSLayoutConstraint activateConstraints:@[
            [dot.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:20],
            [dot.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [dot.widthAnchor    constraintEqualToConstant:10],
            [dot.heightAnchor   constraintEqualToConstant:10],
            [statusLbl.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:12],
            [statusLbl.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
        return cell;
    }

    // ── TOGGLES ──
    if (ip.section == S7TVProxySectionToggles) {
        switch (ip.row) {
            case 0: return S7TVSwitchCell(@"Enable Stream Proxy",
                        @"network", S7TVAccent(),
                        S7TVBool(kTCStreamProxyEnabled), self, @selector(toggleProxyEnabled:));
            case 1: return S7TVSwitchCell(@"Use AVAssetResourceLoader",
                        @"play.circle.fill", [UIColor colorWithWhite:0.75 alpha:1.0],
                        S7TVBool(kTCStreamProxyUseResourceLoader), self, @selector(toggleResourceLoader:));
            case 2: return S7TVSwitchCell(@"Fallback to Direct",
                        @"arrow.uturn.backward.circle.fill", [UIColor colorWithWhite:0.75 alpha:1.0],
                        S7TVBool(kTCStreamProxyFallbackEnabled), self, @selector(toggleFallback:));
            case 3: return S7TVSwitchCell(@"Sanitize Ad Tags",
                        @"scissors", [UIColor colorWithWhite:0.75 alpha:1.0],
                        S7TVBool(kTCStreamProxySanitizeM3U8), self, @selector(toggleSanitize:));
            case 4: return S7TVSwitchCell(@"Proxy Any .m3u8 Host",
                        @"globe", [UIColor colorWithWhite:0.75 alpha:1.0],
                        S7TVBool(kTCStreamProxyAnyM3U8Host), self, @selector(toggleAnyHost:));
            case 5: return S7TVSwitchCell(@"Proxy Token GraphQL Ops",
                        @"dot.radiowaves.left.and.right", [UIColor colorWithWhite:0.75 alpha:1.0],
                        S7TVBool(kTCStreamProxyGraphQLTokenOps), self, @selector(toggleGraphQL:));
            default: return [[UITableViewCell alloc] init];
        }
    }

    // ── PROXY ADDRESS ──
    if (ip.section == S7TVProxySectionAddress) {
        if (ip.row == 0) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.backgroundColor = S7TVCellBg();
            UITextField *field = [[UITextField alloc] init];
            field.text = [ud stringForKey:kTCStreamProxyURL] ?: @"";
            field.placeholder = @"https://proxy.example/proxy?url=$url";
            field.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
            field.textColor = [UIColor whiteColor];
            field.attributedPlaceholder = [[NSAttributedString alloc]
                initWithString:field.placeholder
                    attributes:@{NSForegroundColorAttributeName: S7TVGray()}];
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.keyboardType = UIKeyboardTypeURL;
            field.returnKeyType = UIReturnKeyDone;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            field.translatesAutoresizingMaskIntoConstraints = NO;
            [field addTarget:self action:@selector(proxyURLChanged:) forControlEvents:UIControlEventEditingChanged];
            [cell.contentView addSubview:field];
            [NSLayoutConstraint activateConstraints:@[
                [field.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [field.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [field.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
                [field.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
            ]];
            self.proxyField = field;
            return cell;
        }
        if (ip.row == 1) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.backgroundColor = S7TVCellBg();
            cell.selectedBackgroundView = [[UIView alloc] init];
            cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
            UIImageView *icon = S7TVIcon(@"bolt.fill", S7TVAccent());
            [cell.contentView addSubview:icon];
            UILabel *lbl = [[UILabel alloc] init];
            lbl.text = @"Test Server";
            lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
            lbl.textColor = S7TVAccent();
            lbl.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:lbl];
            [NSLayoutConstraint activateConstraints:@[
                [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [lbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
                [lbl.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
                [lbl.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
            ]];
            return cell;
        }
        if (ip.row == 2)
            return S7TVNavCell(@"Templates", @"Formats prédéfinis",
                               @"list.bullet.rectangle.fill", [UIColor colorWithWhite:0.75 alpha:1.0]);
    }

    // ── SAVED PROXIES ──
    if (ip.section == S7TVProxySectionSaved)
        return S7TVNavCell(@"Saved Proxies", @"Ajouter, modifier, supprimer",
                           @"bookmark.fill", [UIColor colorWithWhite:0.75 alpha:1.0]);

    // ── LOCAL PROXY ──
    if (ip.section == S7TVProxySectionLocal) {
        if (ip.row == 0)
            return S7TVSwitchCell(@"Enable Local Proxy",
                @"iphone.radiowaves.left.and.right", S7TVOrange(),
                S7TVBool(kTCStreamProxyLocalEnabled), self, @selector(toggleLocalProxy:));
        // Port stepper
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = S7TVCellBg();
        UIImageView *icon = S7TVIcon(@"antenna.radiowaves.left.and.right", [UIColor colorWithWhite:0.75 alpha:1.0]);
        [cell.contentView addSubview:icon];
        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = @"Local port";
        lbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        lbl.textColor = [UIColor whiteColor];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:lbl];
        NSInteger port = [ud integerForKey:kTCStreamProxyLocalPort];
        if (port == 0) port = 9595;
        UILabel *portLbl = [[UILabel alloc] init];
        portLbl.text = [NSString stringWithFormat:@"%ld", (long)port];
        portLbl.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        portLbl.textColor = S7TVGray();
        portLbl.tag = 9596;
        portLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:portLbl];
        UIStepper *stepper = [[UIStepper alloc] init];
        stepper.minimumValue = 1024; stepper.maximumValue = 65535;
        stepper.stepValue = 1; stepper.value = port;
        stepper.tag = 9595;
        [stepper addTarget:self action:@selector(localPortChanged:) forControlEvents:UIControlEventValueChanged];
        stepper.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:stepper];
        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor     constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [icon.centerYAnchor     constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [lbl.leadingAnchor      constraintEqualToAnchor:icon.trailingAnchor constant:14],
            [lbl.topAnchor          constraintEqualToAnchor:cell.contentView.topAnchor constant:13],
            [lbl.bottomAnchor       constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-13],
            [stepper.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [stepper.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [portLbl.trailingAnchor constraintEqualToAnchor:stepper.leadingAnchor constant:-10],
            [portLbl.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
        return cell;
    }
    return [[UITableViewCell alloc] init];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == S7TVProxySectionAddress && ip.row == 1) { [self testServer]; return; }
    if (ip.section == S7TVProxySectionAddress && ip.row == 2) {
        [self.navigationController pushViewController:[[S7TVProxyTemplatesController alloc] init] animated:YES]; return;
    }
    if (ip.section == S7TVProxySectionSaved)
        [self.navigationController pushViewController:[[S7TVSavedProxiesController alloc] init] animated:YES];
}

- (void)toggleProxyEnabled:(UISwitch *)sw   { S7TVSetBool(kTCStreamProxyEnabled, sw.isOn); [self refreshStatus]; }
- (void)toggleResourceLoader:(UISwitch *)sw { S7TVSetBool(kTCStreamProxyUseResourceLoader, sw.isOn); }
- (void)toggleFallback:(UISwitch *)sw       { S7TVSetBool(kTCStreamProxyFallbackEnabled, sw.isOn); }
- (void)toggleSanitize:(UISwitch *)sw       { S7TVSetBool(kTCStreamProxySanitizeM3U8, sw.isOn); }
- (void)toggleAnyHost:(UISwitch *)sw        { S7TVSetBool(kTCStreamProxyAnyM3U8Host, sw.isOn); }
- (void)toggleGraphQL:(UISwitch *)sw        { S7TVSetBool(kTCStreamProxyGraphQLTokenOps, sw.isOn); }
- (void)toggleLocalProxy:(UISwitch *)sw     { S7TVSetBool(kTCStreamProxyLocalEnabled, sw.isOn); [self refreshStatus]; }

- (void)proxyURLChanged:(UITextField *)field {
    [[NSUserDefaults standardUserDefaults] setObject:field.text ?: @"" forKey:kTCStreamProxyURL];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)localPortChanged:(UIStepper *)stepper {
    NSInteger port = (NSInteger)stepper.value;
    [[NSUserDefaults standardUserDefaults] setInteger:port forKey:kTCStreamProxyLocalPort];
    [[NSUserDefaults standardUserDefaults] synchronize];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:1 inSection:S7TVProxySectionLocal]];
    UILabel *portLbl = (UILabel *)[cell.contentView viewWithTag:9596];
    portLbl.text = [NSString stringWithFormat:@"%ld", (long)port];
}

- (void)testServer {
    NSString *urlStr = [[NSUserDefaults standardUserDefaults] stringForKey:kTCStreamProxyURL];
    if (!urlStr.length) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"No proxy address"
            message:@"Enter a proxy URL first." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil]; return;
    }
    NSTimeInterval timeout = [[NSUserDefaults standardUserDefaults] doubleForKey:kTCStreamProxyTestTimeout];
    if (timeout <= 0) timeout = 5.0;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = timeout;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    [[session dataTaskWithURL:[NSURL URLWithString:urlStr]
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *result = err ? [NSString stringWithFormat:@"Error: %@", err.localizedDescription] : @"OK ✓";
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Test Server"
                message:result preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    }] resume];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - S7TVProxyTemplatesController
// ─────────────────────────────────────────────────────────────────────────────

@implementation S7TVProxyTemplatesController

- (instancetype)init { self = [super initWithStyle:UITableViewStyleInsetGrouped]; return self; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Templates";
    S7TVStyleTableView(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)S7TVProxyTemplates().count; }
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 44; }
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s { return S7TVSectionHeader(@"Tap to use this proxy", NO); }
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s { return 8; }
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s { UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor]; return v; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 60; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *t = S7TVProxyTemplates()[ip.row];
    return S7TVNavCell(t[@"title"], t[@"url"], @"link", S7TVAccent());
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *url = S7TVProxyTemplates()[ip.row][@"url"];
    [[NSUserDefaults standardUserDefaults] setObject:url forKey:kTCStreamProxyURL];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self.navigationController popViewControllerAnimated:YES];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - S7TVSavedProxiesController
// ─────────────────────────────────────────────────────────────────────────────

@interface S7TVSavedProxiesController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *savedProxies;
@end

@implementation S7TVSavedProxiesController

- (instancetype)init { self = [super initWithStyle:UITableViewStyleInsetGrouped]; return self; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Saved Proxies";
    S7TVStyleTableView(self.tableView);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addProxy)];
    [self reload];
}

- (void)reload {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kTCStreamProxySavedList];
    self.savedProxies = [NSMutableArray arrayWithArray:saved ?: @[]];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.savedProxies.count == 0 ? 1 : (NSInteger)self.savedProxies.count;
}
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 44; }
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s { return S7TVSectionHeader(@"Tap to use · Swipe to delete", NO); }
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s { return 8; }
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s { UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor]; return v; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.savedProxies.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = S7TVCellBg();
        cell.textLabel.text = @"No saved proxies";
        cell.textLabel.textColor = S7TVGray();
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        return cell;
    }
    return S7TVNavCell(self.savedProxies[ip.row], nil, @"bookmark.fill", [UIColor colorWithWhite:0.75 alpha:1.0]);
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.savedProxies.count == 0) return;
    [[NSUserDefaults standardUserDefaults] setObject:self.savedProxies[ip.row] forKey:kTCStreamProxyURL];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self.navigationController popViewControllerAnimated:YES];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return self.savedProxies.count > 0; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return self.savedProxies.count > 0 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)es forRowAtIndexPath:(NSIndexPath *)ip {
    if (es != UITableViewCellEditingStyleDelete) return;
    [self.savedProxies removeObjectAtIndex:ip.row];
    [[NSUserDefaults standardUserDefaults] setObject:[self.savedProxies copy] forKey:kTCStreamProxySavedList];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self reload];
}

- (void)addProxy {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Proxy"
        message:@"Save a proxy URL for quick reuse." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://proxy.example/proxy?url=$url";
        tf.keyboardType = UIKeyboardTypeURL;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *url = alert.textFields.firstObject.text;
        if (!url.length) return;
        [self.savedProxies addObject:url];
        [[NSUserDefaults standardUserDefaults] setObject:[self.savedProxies copy] forKey:kTCStreamProxySavedList];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [self reload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - S7TVLiveStreamController
// ─────────────────────────────────────────────────────────────────────────────

@implementation S7TVLiveStreamController

- (instancetype)init { self = [super initWithStyle:UITableViewStyleInsetGrouped]; return self; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Live Stream Control";
    S7TVStyleTableView(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 3; }
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 44; }
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s { return S7TVSectionHeader(@"Live Stream Control", NO); }
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s { return UITableViewAutomaticDimension; }

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *container = [[UIView alloc] init];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = @"Auto Collect Channel Points automatically claims the live channel-points chest when it appears in chat. The Ad Bypassed Indicator displays a small alert in the corner when an ad segment is actively skipped by the proxy. Enabling Show Ad Type Tag appends the ad classification (e.g. Commercial or Stitched) directly inside the indicator pill.";
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    lbl.textColor = S7TVGray();
    lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
        [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [lbl.topAnchor      constraintEqualToAnchor:container.topAnchor constant:6],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-6],
    ]];
    return container;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    switch (ip.row) {
        case 0: return S7TVSwitchCell(@"Auto Collect Channel Points",
                    @"giftcard.fill", [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0],
                    S7TVBool(kTCLiveAutoCollectChannelPoints), self, @selector(toggleAutoCollect:));
        case 1: return S7TVSwitchCell(@"Ad Bypassed Indicator",
                    @"checkmark.shield.fill", S7TVGreen(),
                    S7TVBool(kTCAdsBypassIndicatorEnabled), self, @selector(toggleBypassIndicator:));
        case 2: return S7TVSwitchCell(@"Show Ad Type Tag",
                    @"tag.fill", [UIColor colorWithWhite:0.75 alpha:1.0],
                    S7TVBool(kTCAdsBypassIndicatorTagEnabled), self, @selector(toggleAdTypeTag:));
        default: return [[UITableViewCell alloc] init];
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [tv deselectRowAtIndexPath:ip animated:YES]; }
- (void)toggleAutoCollect:(UISwitch *)sw     { S7TVSetBool(kTCLiveAutoCollectChannelPoints, sw.isOn); }
- (void)toggleBypassIndicator:(UISwitch *)sw { S7TVSetBool(kTCAdsBypassIndicatorEnabled, sw.isOn); }
- (void)toggleAdTypeTag:(UISwitch *)sw       { S7TVSetBool(kTCAdsBypassIndicatorTagEnabled, sw.isOn); }

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - S7TVDisableAdsController
// ─────────────────────────────────────────────────────────────────────────────

@implementation S7TVDisableAdsController

- (instancetype)init { self = [super initWithStyle:UITableViewStyleInsetGrouped]; return self; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Disable Ads";
    S7TVStyleTableView(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 1; }
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 44; }
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s { return S7TVSectionHeader(@"Disable Ads", NO); }
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s { return UITableViewAutomaticDimension; }

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *container = [[UIView alloc] init];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = @"Disable Ads on/off. Disabling ads applies immediately to active Twitch windows.";
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    lbl.textColor = S7TVGray();
    lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
        [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [lbl.topAnchor      constraintEqualToAnchor:container.topAnchor constant:6],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-6],
    ]];
    return container;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    return S7TVSwitchCell(@"Disable Ads", @"hand.raised.slash.fill",
                          [UIColor colorWithWhite:0.75 alpha:1.0],
                          S7TVBool(kTCAdsDisabled), self, @selector(toggleAds:));
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [tv deselectRowAtIndexPath:ip animated:YES]; }
- (void)toggleAds:(UISwitch *)sw { S7TVSetBool(kTCAdsDisabled, sw.isOn); }

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - S7TVBlockedURLsController
// ─────────────────────────────────────────────────────────────────────────────

@interface S7TVBlockedURLsController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *entries;
@end

@implementation S7TVBlockedURLsController

- (instancetype)init { self = [super initWithStyle:UITableViewStyleInsetGrouped]; return self; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Blocked URLs";
    S7TVStyleTableView(self.tableView);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addEntry)];
    [self reload];
}

- (void)reload {
    self.entries = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:kTCBlockedURLList] ?: @[]];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.entries.count == 0 ? 1 : (NSInteger)self.entries.count;
}
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 44; }
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    NSString *t = self.entries.count > 0
        ? [NSString stringWithFormat:@"Blocked URLs — %lu rules", (unsigned long)self.entries.count]
        : @"Blocked URLs";
    return S7TVSectionHeader(t, NO);
}
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s { return UITableViewAutomaticDimension; }
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *container = [[UIView alloc] init];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = @"Add entries to block requests. Enter a host, URL, or regex (re:pattern).";
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    lbl.textColor = S7TVGray(); lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
        [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [lbl.topAnchor      constraintEqualToAnchor:container.topAnchor constant:6],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-6],
    ]];
    return container;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.entries.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = S7TVCellBg();
        cell.textLabel.text = @"No blocked URLs"; cell.textLabel.textColor = S7TVGray();
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        return cell;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = S7TVCellBg();
    UIImageView *icon = S7TVIcon(@"minus.circle.fill", S7TVRed());
    [cell.contentView addSubview:icon];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = self.entries[ip.row];
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor whiteColor]; lbl.numberOfLines = 1;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [lbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [lbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [lbl.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [lbl.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
    ]];
    return cell;
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return self.entries.count > 0; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return self.entries.count > 0 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)es forRowAtIndexPath:(NSIndexPath *)ip {
    if (es != UITableViewCellEditingStyleDelete) return;
    [self.entries removeObjectAtIndex:ip.row];
    [[NSUserDefaults standardUserDefaults] setObject:[self.entries copy] forKey:kTCBlockedURLList];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self reload];
}

- (void)addEntry {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Blocked URL"
        message:@"Enter a host, URL, or regex (re:pattern)." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"e.g. edge.ads.twitch.tv";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *entry = alert.textFields.firstObject.text;
        if (!entry.length) return;
        [self.entries addObject:entry];
        [[NSUserDefaults standardUserDefaults] setObject:[self.entries copy] forKey:kTCBlockedURLList];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [self reload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - S7TVExcludedURLsController
// ─────────────────────────────────────────────────────────────────────────────

@interface S7TVExcludedURLsController ()
@property (nonatomic, strong) NSMutableArray<NSString *> *entries;
@end

@implementation S7TVExcludedURLsController

- (instancetype)init { self = [super initWithStyle:UITableViewStyleInsetGrouped]; return self; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Excluded URLs";
    S7TVStyleTableView(self.tableView);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addEntry)];
    [self reload];
}

- (void)reload {
    self.entries = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:kTCExcludedURLList] ?: @[]];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.entries.count == 0 ? 1 : (NSInteger)self.entries.count;
}
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 44; }
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    NSString *t = self.entries.count > 0
        ? [NSString stringWithFormat:@"Excluded URLs — %lu entries", (unsigned long)self.entries.count]
        : @"Excluded URLs";
    return S7TVSectionHeader(t, NO);
}
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s { return UITableViewAutomaticDimension; }
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    UIView *container = [[UIView alloc] init];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = @"Add entries to hide them from capture. Enter a host or domain (e.g., playlist.ttvnw.net).";
    lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    lbl.textColor = S7TVGray(); lbl.numberOfLines = 0;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:16],
        [lbl.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [lbl.topAnchor      constraintEqualToAnchor:container.topAnchor constant:6],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-6],
    ]];
    return container;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.entries.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = S7TVCellBg();
        cell.textLabel.text = @"No excluded URLs"; cell.textLabel.textColor = S7TVGray();
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        return cell;
    }
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = S7TVCellBg();
    UIImageView *icon = S7TVIcon(@"eye.slash.fill", [UIColor colorWithWhite:0.75 alpha:1.0]);
    [cell.contentView addSubview:icon];
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = self.entries[ip.row];
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    lbl.textColor = [UIColor whiteColor]; lbl.numberOfLines = 1;
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [lbl.leadingAnchor  constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [lbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [lbl.topAnchor      constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [lbl.bottomAnchor   constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
    ]];
    return cell;
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return self.entries.count > 0; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return self.entries.count > 0 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)es forRowAtIndexPath:(NSIndexPath *)ip {
    if (es != UITableViewCellEditingStyleDelete) return;
    [self.entries removeObjectAtIndex:ip.row];
    [[NSUserDefaults standardUserDefaults] setObject:[self.entries copy] forKey:kTCExcludedURLList];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self reload];
}

- (void)addEntry {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Excluded URL"
        message:@"Enter a host or domain to exclude from capture." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"e.g., playlist.ttvnw.net";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *entry = alert.textFields.firstObject.text;
        if (!entry.length) return;
        [self.entries addObject:entry];
        [[NSUserDefaults standardUserDefaults] setObject:[self.entries copy] forKey:kTCExcludedURLList];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [self reload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
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
    return s == 0 ? 1 : 2; // section 1 : animées + picker (favoris déplacés vers Statistiques)
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
        default: return [[UITableViewCell alloc] init];
    }
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
}

- (void)toggleEnabled:(UISwitch *)sw          { [SevenTVManager sharedManager].isEnabled           = sw.isOn; }
- (void)toggleAnimated:(UISwitch *)sw         { [SevenTVManager sharedManager].showAnimated         = sw.isOn; }
- (void)togglePickerAnimations:(UISwitch *)sw { [SevenTVManager sharedManager].showPickerAnimations = sw.isOn; }

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVStatsPageController
// ─────────────────────────────────────────────────────────────────────────────

@interface SevenTVStatsPageController () <UIDocumentPickerDelegate>
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

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case 0: return 1;  // Channel actif
        case 1: return 3;  // Emotes chargées
        case 2: return 2;  // Favoris (count + import)
        default: return 0;
    }
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 ? 64 : 52;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return S7TVSectionHeader(@"Channel actif",    NO);
        case 1: return S7TVSectionHeader(@"Emotes chargées",  NO);
        case 2: return S7TVSectionHeader(@"Favoris",          NO);
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

    // ── Section 2 : Favoris ─────────────────────────────────────────────────
    if (ip.section == 2) {
        NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
        NSArray *favs = [prefs arrayForKey:@"s7tv_favorites"] ?: @[];

        if (ip.row == 0) {
            // Cellule tappable : ouvre la liste des favoris
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            cell.accessoryType  = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectedBackgroundView = [[UIView alloc] init];
            cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];

            UIImageView *icon = S7TVIcon(@"star.fill",
                [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]);
            [cell.contentView addSubview:icon];

            UILabel *lbl = [[UILabel alloc] init];
            lbl.text = @"Emotes en favoris";
            lbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
            lbl.textColor = [UIColor whiteColor];
            lbl.numberOfLines = 1;
            lbl.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:lbl];

            UILabel *countLbl = [[UILabel alloc] init];
            countLbl.text = [NSString stringWithFormat:@"%lu", (unsigned long)favs.count];
            countLbl.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
            countLbl.textColor = [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0];
            countLbl.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:countLbl];

            [NSLayoutConstraint activateConstraints:@[
                [icon.leadingAnchor     constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [icon.centerYAnchor     constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [lbl.leadingAnchor      constraintEqualToAnchor:icon.trailingAnchor constant:14],
                [lbl.topAnchor          constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
                [lbl.bottomAnchor       constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
                [countLbl.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
                [countLbl.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            ]];
            return cell;
        }

        // Row 1 : Importer depuis fichier PC
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectedBackgroundView = [[UIView alloc] init];
        cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];

        UIImageView *importIcon = S7TVIcon(@"square.and.arrow.down",
            [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0]);
        [cell.contentView addSubview:importIcon];

        UILabel *importLbl = [[UILabel alloc] init];
        importLbl.text = @"Importer depuis PC";
        importLbl.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        importLbl.textColor = [UIColor whiteColor];
        importLbl.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *importSub = [[UILabel alloc] init];
        importSub.text = @"Export JSON 7TV (Settings → … → Export)";
        importSub.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        importSub.textColor = S7TVGray();
        importSub.translatesAutoresizingMaskIntoConstraints = NO;

        UIStackView *importStack = [[UIStackView alloc]
            initWithArrangedSubviews:@[importLbl, importSub]];
        importStack.axis      = UILayoutConstraintAxisVertical;
        importStack.spacing   = 2;
        importStack.alignment = UIStackViewAlignmentLeading;
        importStack.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:importStack];

        [NSLayoutConstraint activateConstraints:@[
            [importIcon.leadingAnchor   constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [importIcon.centerYAnchor   constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [importStack.leadingAnchor  constraintEqualToAnchor:importIcon.trailingAnchor constant:14],
            [importStack.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [importStack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-8],
            [importStack.topAnchor      constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor constant:8],
            [importStack.bottomAnchor   constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        ]];
        return cell;
    }

    // ── Section 1 : Emotes chargées ─────────────────────────────────────────
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
    if (ip.section == 2 && ip.row == 0) {
        // Ouvre la liste des favoris
        SevenTVFavoritesListController *favsVC = [[SevenTVFavoritesListController alloc] init];
        [self.navigationController pushViewController:favsVC animated:YES];
        return;
    }
    if (ip.section == 2 && ip.row == 1) {
        [self importFavoritesFromFile];
    }
}

// ── Import favoris depuis fichier JSON 7TV PC ────────────────────────────────

- (void)importFavoritesFromFile {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.json", @"public.text", @"public.data"]
                       inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle  = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&err];
    if (!data) {
        [self s7tv_showAlert:@"Erreur"
                     message:@"Impossible de lire le fichier."];
        return;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!json) {
        [self s7tv_showAlert:@"Format invalide"
                     message:@"Le fichier n'est pas un JSON valide."];
        return;
    }

    // L'export 7TV PC peut avoir deux structures :
    //   - Tableau directement : [ "7TV:xxx", ... ]
    //   - Dict racine avec "ui.emote_menu.favorites" (format v0 hypothétique)
    //   - Dict racine avec "settings" → "ui.emote_menu.favorites" (format réel v1)
    NSArray *rawFavs = nil;
    if ([json isKindOfClass:[NSArray class]]) {
        rawFavs = (NSArray *)json;
    } else if ([json isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)json;
        // Format réel : { "settings": { "ui.emote_menu.favorites": [...] } }
        NSDictionary *settings = dict[@"settings"];
        if ([settings isKindOfClass:[NSDictionary class]]) {
            rawFavs = settings[@"ui.emote_menu.favorites"];
        }
        // Fallback : clé à la racine (format alternatif)
        if (!rawFavs) {
            rawFavs = dict[@"ui.emote_menu.favorites"];
        }
    }

    if (!rawFavs) {
        [self s7tv_showAlert:@"Format inconnu"
                     message:@"Clé « ui.emote_menu.favorites » introuvable.\nVérifie que c'est bien un export 7TV PC."];
        return;
    }

    // Filtrer les entrées "7TV:<id>" — ignorer "PLATFORM:..."
    NSMutableArray<NSString *> *newIDs = [NSMutableArray array];
    for (id entry in rawFavs) {
        if (![entry isKindOfClass:[NSString class]]) continue;
        NSString *s = (NSString *)entry;
        if ([s hasPrefix:@"7TV:"]) {
            [newIDs addObject:[s substringFromIndex:4]];
        }
    }

    if (newIDs.count == 0) {
        [self s7tv_showAlert:@"Aucun favori 7TV"
                     message:@"Ce fichier ne contient pas d'emotes 7TV en favoris."];
        return;
    }

    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *existing = [prefs arrayForKey:@"s7tv_favorites"] ?: @[];
    NSMutableOrderedSet<NSString *> *merged =
        [NSMutableOrderedSet orderedSetWithArray:existing];
    NSUInteger beforeCount = merged.count;
    [merged addObjectsFromArray:newIDs];
    [prefs setObject:merged.array forKey:@"s7tv_favorites"];
    [prefs synchronize];

    NSUInteger added = merged.count - beforeCount;
    NSUInteger skipped = newIDs.count - added;
    [self.tableView reloadData];
    [self s7tv_showAlert:[NSString stringWithFormat:@"%lu emote(s) ajoutée(s)", (unsigned long)added]
                 message:[NSString stringWithFormat:
                          @"%lu nouvelle(s) importée(s), %lu déjà en favoris.",
                          (unsigned long)added,
                          (unsigned long)skipped]];
    [[SevenTVManager sharedManager] log:@"📥 Import favoris 7TV : %lu total, %lu ajoutés",
     (unsigned long)merged.count, (unsigned long)added];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { }

- (void)s7tv_showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                          style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SevenTVFavoritesListController
// Liste de toutes les emotes en favoris (IDs 7TV + noms résolus).
// ─────────────────────────────────────────────────────────────────────────────

@implementation SevenTVFavoritesListController {
    NSArray<NSString *> *_favIDs;      // IDs purs (sans préfixe)
    NSDictionary<NSString *, NSString *> *_idToName; // emoteID → emoteName
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Mes favoris";
    S7TVStyleTableView(self.tableView);
    [self reloadFavs];

    // Bouton Vider
    UIBarButtonItem *clear = [[UIBarButtonItem alloc]
        initWithTitle:@"Vider"
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(clearAllFavs)];
    clear.tintColor = [UIColor systemRedColor];
    self.navigationItem.rightBarButtonItem = clear;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFavs];
}

- (void)reloadFavs {
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    _favIDs = [[prefs arrayForKey:@"s7tv_favorites"] ?: @[] copy];

    // Construire le dictionnaire id → nom à partir des emotes chargées
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    void (^scan)(NSDictionary<NSString *, SevenTVEmote *> *) = ^(NSDictionary *dict) {
        [dict enumerateKeysAndObjectsUsingBlock:^(NSString *name, SevenTVEmote *emote, BOOL *stop) {
            if (emote.emoteID) map[emote.emoteID] = name;
        }];
    };
    dispatch_sync(mgr.emoteQueue, ^{
        scan(mgr.globalEmotes ?: @{});
        scan(mgr.channelEmotes ?: @{});
    });
    _idToName = [map copy];

    [self.tableView reloadData];
}

// ── TableView ──

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return _favIDs.count == 0 ? 1 : (NSInteger)_favIDs.count;
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return 44;
}

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    NSString *title = _favIDs.count > 0
        ? [NSString stringWithFormat:@"%lu emote(s) en favoris", (unsigned long)_favIDs.count]
        : @"Favoris";
    return S7TVSectionHeader(title, NO);
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    return 52;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {

    // Cas liste vide
    if (_favIDs.count == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc]
            initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle  = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = S7TVCellBg();
        cell.textLabel.text  = @"Aucun favori pour l'instant.";
        cell.textLabel.textColor = S7TVGray();
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
        return cell;
    }

    NSString *emoteID = _favIDs[ip.row];
    NSString *name    = _idToName[emoteID];   // nil si emote pas chargée

    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.backgroundColor = S7TVCellBg();
    cell.selectedBackgroundView = [[UIView alloc] init];
    cell.selectedBackgroundView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];

    // Image emote (chargée via URLCache si dispo)
    UIImageView *thumb = [[UIImageView alloc] init];
    thumb.contentMode = UIViewContentModeScaleAspectFit;
    thumb.translatesAutoresizingMaskIntoConstraints = NO;
    thumb.clipsToBounds = YES;
    [cell.contentView addSubview:thumb];

    // Essayer de trouver l'image en cache
    NSString *urlStr = [NSString stringWithFormat:@"https://cdn.7tv.app/emote/%@/1x.webp", emoteID];
    NSURL *cdnURL = [NSURL URLWithString:urlStr];
    NSURLRequest *req = [NSURLRequest requestWithURL:cdnURL];
    NSCachedURLResponse *cached = [[SevenTVURLProtocol sharedEmoteCache] cachedResponseForRequest:req];
    if (cached) {
        UIImage *img = [UIImage imageWithData:cached.data];
        thumb.image = img;
    } else {
        // Placeholder étoile violette
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
        thumb.image = [UIImage systemImageNamed:@"star.fill" withConfiguration:cfg];
        thumb.tintColor = [UIColor colorWithRed:0.60 green:0.35 blue:1.0 alpha:1.0];

        // Télécharge en arrière-plan et met à jour si la cellule est encore visible
        NSIndexPath *indexPath = ip;
        [SevenTVURLProtocol prefetchEmoteID:emoteID completion:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                UITableViewCell *visible = [tv cellForRowAtIndexPath:indexPath];
                if (!visible) return;
                UIImageView *iv = (UIImageView *)[visible.contentView viewWithTag:7700];
                NSCachedURLResponse *r = [[SevenTVURLProtocol sharedEmoteCache]
                    cachedResponseForRequest:req];
                if (r) iv.image = [UIImage imageWithData:r.data];
            });
        }];
    }
    thumb.tag = 7700;

    // Labels
    UILabel *nameLbl = [[UILabel alloc] init];
    nameLbl.text = name ?: @"(emote non chargée)";
    nameLbl.font = [UIFont systemFontOfSize:15 weight:
        name ? UIFontWeightRegular : UIFontWeightLight];
    nameLbl.textColor = name ? [UIColor whiteColor] : S7TVGray();
    nameLbl.numberOfLines = 1;
    nameLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:nameLbl];

    UILabel *idLbl = [[UILabel alloc] init];
    // Tronquer l'ID pour ne pas déborder
    NSString *shortID = emoteID.length > 14
        ? [NSString stringWithFormat:@"%@…", [emoteID substringToIndex:14]]
        : emoteID;
    idLbl.text = shortID;
    idLbl.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    idLbl.textColor = S7TVGray();
    idLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:idLbl];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[nameLbl, idLbl]];
    stack.axis      = UILayoutConstraintAxisVertical;
    stack.spacing   = 2;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:stack];

    // Bouton supprimer (swipe to delete géré via editingStyle, mais on ajoute aussi un bouton trash)
    [NSLayoutConstraint activateConstraints:@[
        [thumb.leadingAnchor  constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [thumb.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [thumb.widthAnchor    constraintEqualToConstant:32],
        [thumb.heightAnchor   constraintEqualToConstant:32],
        [stack.leadingAnchor  constraintEqualToAnchor:thumb.trailingAnchor constant:14],
        [stack.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [stack.topAnchor      constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor constant:8],
        [stack.bottomAnchor   constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
    ]];

    return cell;
}

// Swipe-to-delete
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return _favIDs.count > 0;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tv
           editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    return _favIDs.count > 0 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tv
commitEditingStyle:(UITableViewCellEditingStyle)es
forRowAtIndexPath:(NSIndexPath *)ip {
    if (es != UITableViewCellEditingStyleDelete) return;
    NSString *removedID = _favIDs[ip.row];
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
    NSMutableArray *cur = [([prefs arrayForKey:@"s7tv_favorites"] ?: @[]) mutableCopy];
    [cur removeObject:removedID];
    [prefs setObject:cur forKey:@"s7tv_favorites"];
    [prefs synchronize];
    [self reloadFavs];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
}

// Bouton Vider
- (void)clearAllFavs {
    if (_favIDs.count == 0) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Vider les favoris"
                         message:@"Supprimer les %lu emotes en favoris ?"
        preferredStyle:UIAlertControllerStyleActionSheet];
    alert.message = [NSString stringWithFormat:@"Supprimer les %lu emotes en favoris ?",
                     (unsigned long)_favIDs.count];
    [alert addAction:[UIAlertAction actionWithTitle:@"Vider"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];
            [prefs removeObjectForKey:@"s7tv_favorites"];
            [prefs synchronize];
            [self reloadFavs];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Annuler"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
    switch (s) { case 0: return 3; case 1: return 1; case 2: return 1; default: return 0; }
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
            case 2: return S7TVSwitchCell(@"Bouton flottant 7TV",
                        @"circle.grid.2x1.fill",
                        [UIColor colorWithWhite:0.75 alpha:1.0],
                        mgr.showFloatingButton,
                        self, @selector(toggleFloatingButton:));
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

- (void)toggleDebug:(UISwitch *)sw        { [SevenTVManager sharedManager].debugLogging    = sw.isOn; }
- (void)toggleTapLog:(UISwitch *)sw       { [SevenTVManager sharedManager].tapLogging       = sw.isOn; }
- (void)toggleFloatingButton:(UISwitch *)sw { [SevenTVManager sharedManager].showFloatingButton = sw.isOn; }

@end
