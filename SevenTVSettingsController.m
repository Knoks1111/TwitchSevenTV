/*
 * SevenTVSettingsController.m
 * Paramètres 7TV avec sections collapsibles.
 * Tap sur un header → ouvre/ferme la section.
 */

#import "SevenTVSettingsController.h"
#import "SevenTVManager.h"
#import "SevenTVLogsController.h"

static NSString *const kSwitchCell = @"SwitchCell";
static NSString *const kInfoCell   = @"InfoCell";
static NSString *const kActionCell = @"ActionCell";

// Sections
typedef NS_ENUM(NSInteger, S7TVSection) {
    S7TVSectionEmotes = 0,
    S7TVSectionStats  = 1,
    S7TVSectionLogs   = 2,
    S7TVSectionCount  = 3
};

@interface SevenTVSettingsController ()
@property (nonatomic, strong) NSMutableSet<NSNumber *> *expandedSections;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end


@implementation SevenTVSettingsController

// ============================================================
// MARK: - Init
// ============================================================

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Paramètres 7TV";

    // Toutes les sections fermées par défaut
    self.expandedSections = [NSMutableSet set];

    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self action:@selector(closeTapped)];
    self.navigationItem.rightBarButtonItem = closeBtn;

    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                         target:self
                                                       selector:@selector(refreshStats)
                                                       userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)closeTapped { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)refreshStats {
    if ([self.expandedSections containsObject:@(S7TVSectionStats)]) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:S7TVSectionStats]
                      withRowAnimation:UITableViewRowAnimationNone];
    }
}


// ============================================================
// MARK: - Structure
// ============================================================

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return S7TVSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // Si la section est fermée → 0 lignes (le header reste visible)
    if (![self.expandedSections containsObject:@(section)]) return 0;
    switch (section) {
        case S7TVSectionEmotes: return 4;
        case S7TVSectionStats:  return 4;
        case S7TVSectionLogs:   return 4;
        default: return 0;
    }
}

// ── Header personnalisé avec chevron ──────────────────────────────────────

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    BOOL expanded = [self.expandedSections containsObject:@(section)];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 48)];
    header.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    header.layer.cornerRadius = 10;
    header.clipsToBounds = YES;

    // Icône + titre
    NSString *icon, *title;
    switch (section) {
        case S7TVSectionEmotes: icon = @"🟣"; title = @"Emotes 7TV";    break;
        case S7TVSectionStats:  icon = @"📊"; title = @"Statistiques";  break;
        case S7TVSectionLogs:   icon = @"🪵"; title = @"Logs";          break;
        default: icon = @""; title = @"";
    }

    UILabel *iconLbl = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, 28, 48)];
    iconLbl.text = icon;
    iconLbl.font = [UIFont systemFontOfSize:18];
    [header addSubview:iconLbl];

    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(48, 0, tableView.bounds.size.width - 96, 48)];
    titleLbl.text = title;
    titleLbl.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    titleLbl.textColor = [UIColor labelColor];
    [header addSubview:titleLbl];

    // Chevron
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
        configurationWithPointSize:13 weight:UIImageSymbolWeightMedium];
    NSString *chevronName = expanded ? @"chevron.up" : @"chevron.down";
    UIImageView *chevron = [[UIImageView alloc] initWithImage:
        [UIImage systemImageNamed:chevronName withConfiguration:cfg]];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    CGFloat cSize = 20;
    chevron.frame = CGRectMake(tableView.bounds.size.width - cSize - 20,
                               (48 - cSize) / 2, cSize, cSize);
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    [header addSubview:chevron];

    // Tap gesture sur le header
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(headerTapped:)];
    header.tag = section;
    [header addGestureRecognizer:tap];
    header.userInteractionEnabled = YES;

    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 52;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    // Petit espace sous chaque section
    return 8;
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [[UIView alloc] init];
}

// ── Toggle section ─────────────────────────────────────────────────────────

- (void)headerTapped:(UITapGestureRecognizer *)tap {
    NSInteger section = tap.view.tag;
    NSNumber *key = @(section);
    BOOL wasExpanded = [self.expandedSections containsObject:key];

    [self.tableView beginUpdates];
    if (wasExpanded) {
        [self.expandedSections removeObject:key];
    } else {
        [self.expandedSections addObject:key];
    }
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section]
                  withRowAnimation:UITableViewRowAnimationFade];
    [self.tableView endUpdates];
}


// ============================================================
// MARK: - Cellules
// ============================================================

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    SevenTVManager *mgr = [SevenTVManager sharedManager];

    switch (indexPath.section) {

        // ── Emotes 7TV ────────────────────────────────────────────────────
        case S7TVSectionEmotes: {
            switch (indexPath.row) {
                case 0: return [self switchCellWithTitle:@"Activer les emotes 7TV"
                                                   icon:@"🟣" isOn:mgr.isEnabled
                                                 action:@selector(toggleEnabled:)];
                case 1: return [self switchCellWithTitle:@"Emotes animées dans le chat"
                                                   icon:@"✨" isOn:mgr.showAnimated
                                                 action:@selector(toggleAnimated:)];
                case 2: return [self switchCellWithTitle:@"Emotes animées dans le picker"
                                                   icon:@"🎞️" isOn:mgr.showPickerAnimations
                                                 action:@selector(togglePickerAnimations:)];
                case 3: return [self switchCellWithTitle:@"Bouton flottant 7TV"
                                                   icon:@"💜" isOn:mgr.showFloatingButton
                                                 action:@selector(toggleFloatingButton:)];
                default: return [[UITableViewCell alloc] init];
            }
        }

        // ── Statistiques ──────────────────────────────────────────────────
        case S7TVSectionStats: {
            UITableViewCell *cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kInfoCell];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            NSUInteger g = mgr.globalEmotes.count, c = mgr.channelEmotes.count;
            switch (indexPath.row) {
                case 0: cell.textLabel.text = @"Channel actuel";
                        cell.detailTextLabel.text = mgr.currentChannelName ?: @"Aucun"; break;
                case 1: cell.textLabel.text = @"Emotes globales";
                        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)g]; break;
                case 2: cell.textLabel.text = @"Emotes du channel";
                        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)c]; break;
                case 3: cell.textLabel.text = @"Total";
                        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)(g+c)];
                        cell.textLabel.font = [UIFont boldSystemFontOfSize:cell.textLabel.font.pointSize]; break;
            }
            return cell;
        }

        // ── Logs ──────────────────────────────────────────────────────────
        case S7TVSectionLogs: {
            switch (indexPath.row) {
                case 0: return [self switchCellWithTitle:@"Logs console (Console.app)"
                                                   icon:@"🖥️" isOn:mgr.debugLogging
                                                 action:@selector(toggleDebug:)];
                case 1: return [self switchCellWithTitle:@"Tap logger"
                                                   icon:@"👆" isOn:mgr.tapLogging
                                                 action:@selector(toggleTapLog:)];
                case 2: {
                    UITableViewCell *cell = [[UITableViewCell alloc]
                        initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kInfoCell];
                    cell.textLabel.text      = @"Voir les logs";
                    cell.textLabel.textColor = self.view.tintColor;
                    NSUInteger n = [mgr allLogs].count;
                    cell.detailTextLabel.text = n > 0
                        ? [NSString stringWithFormat:@"%lu lignes", (unsigned long)n] : @"";
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    return cell;
                }
                case 3: {
                    UITableViewCell *cell = [[UITableViewCell alloc]
                        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kActionCell];
                    cell.textLabel.text      = @"🔄  Recharger les emotes";
                    cell.textLabel.textColor = self.view.tintColor;
                    return cell;
                }
                default: return [[UITableViewCell alloc] init];
            }
        }

        default: return [[UITableViewCell alloc] init];
    }
}


// ============================================================
// MARK: - Tap cellules
// ============================================================

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == S7TVSectionLogs) {
        if (indexPath.row == 2) [self openLogsViewer];
        if (indexPath.row == 3) [self reloadEmotes];
    }
}

- (void)openLogsViewer {
    [self.navigationController pushViewController:[[SevenTVLogsController alloc] init] animated:YES];
}

- (void)reloadEmotes {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr loadGlobalEmotes];
    if (mgr.currentChannelTwitchID) [mgr loadEmotesForChannelTwitchID:mgr.currentChannelTwitchID];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Rechargement lancé"
                         message:@"Les emotes seront disponibles dans quelques secondes."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}


// ============================================================
// MARK: - Toggles
// ============================================================

- (void)toggleEnabled:(UISwitch *)sw          { [SevenTVManager sharedManager].isEnabled           = sw.isOn; }
- (void)toggleAnimated:(UISwitch *)sw         { [SevenTVManager sharedManager].showAnimated         = sw.isOn; }
- (void)togglePickerAnimations:(UISwitch *)sw { [SevenTVManager sharedManager].showPickerAnimations = sw.isOn; }
- (void)toggleFloatingButton:(UISwitch *)sw   { [SevenTVManager sharedManager].showFloatingButton   = sw.isOn; }
- (void)toggleDebug:(UISwitch *)sw            { [SevenTVManager sharedManager].debugLogging         = sw.isOn; }
- (void)toggleTapLog:(UISwitch *)sw           { [SevenTVManager sharedManager].tapLogging           = sw.isOn; }


// ============================================================
// MARK: - Helper cellule switch
// ============================================================

- (UITableViewCell *)switchCellWithTitle:(NSString *)title
                                    icon:(NSString *)icon
                                    isOn:(BOOL)isOn
                                  action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kSwitchCell];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  %@", icon, title];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = isOn;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

@end
