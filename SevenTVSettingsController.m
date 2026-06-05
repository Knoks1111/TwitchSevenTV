/*
 * SevenTVSettingsController.m
 *
 * Interface de paramètres native iOS (UITableViewController).
 * Accessible via le bouton flottant "7TV" dans l'app Twitch.
 *
 * Sections:
 *   0. Emotes 7TV  — activation, animées chat, animées picker, bouton flottant
 *   1. Statistiques — channel, emotes globales, emotes channel, total
 *   2. Logs         — logs console, tap logger, voir les logs, recharger
 *   3. À propos     — version, API
 */

#import "SevenTVSettingsController.h"
#import "SevenTVManager.h"
#import "SevenTVLogsController.h"

static NSString *const kSwitchCell = @"SwitchCell";
static NSString *const kInfoCell   = @"InfoCell";
static NSString *const kActionCell = @"ActionCell";

@interface SevenTVSettingsController ()
@property (nonatomic, strong) NSTimer *refreshTimer;
@end


@implementation SevenTVSettingsController

// ============================================================
// MARK: - Initialisation
// ============================================================

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Paramètres 7TV";

    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                             target:self
                             action:@selector(closeTapped)];
    self.navigationItem.rightBarButtonItem = closeBtn;

    // Rafraîchir les stats toutes les 2 secondes
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                         target:self
                                                       selector:@selector(refreshStats)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refreshStats {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationNone];
}


// ============================================================
// MARK: - Structure
// ============================================================

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Emotes 7TV";
        case 1: return @"Statistiques";
        case 2: return @"Logs";
        case 3: return @"À propos";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return @"\"Animées dans le picker\" anime uniquement les emotes en favoris "
                   @"(long press sur une emote pour la mettre en favori).";
        case 2:
            return @"\"Tap logger\" enregistre chaque tap dans la vue. "
                   @"\"Logs console\" envoie aussi les logs vers Console.app (Mac).";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 4;  // 7TV on/off, animées chat, animées picker, bouton flottant
        case 1: return 4;  // channel, globales, channel emotes, total
        case 2: return 4;  // logs console, tap logger, voir logs, recharger
        case 3: return 2;  // version, API
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    SevenTVManager *mgr = [SevenTVManager sharedManager];

    switch (indexPath.section) {

        // ── Section 0: Emotes 7TV ──────────────────────────────────────────
        case 0: {
            switch (indexPath.row) {
                case 0:
                    return [self switchCellWithTitle:@"Activer les emotes 7TV"
                                               icon:@"🟣"
                                               isOn:mgr.isEnabled
                                             action:@selector(toggleEnabled:)];
                case 1:
                    return [self switchCellWithTitle:@"Emotes animées dans le chat"
                                               icon:@"✨"
                                               isOn:mgr.showAnimated
                                             action:@selector(toggleAnimated:)];
                case 2:
                    return [self switchCellWithTitle:@"Emotes animées dans le picker"
                                               icon:@"🎞️"
                                               isOn:mgr.showPickerAnimations
                                             action:@selector(togglePickerAnimations:)];
                case 3:
                    return [self switchCellWithTitle:@"Bouton flottant 7TV"
                                               icon:@"💜"
                                               isOn:mgr.showFloatingButton
                                             action:@selector(toggleFloatingButton:)];
                default:
                    return [[UITableViewCell alloc] init];
            }
        }

        // ── Section 1: Statistiques ────────────────────────────────────────
        case 1: {
            UITableViewCell *cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleValue1
               reuseIdentifier:kInfoCell];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;

            NSString *channelName   = mgr.currentChannelName ?: @"Aucun";
            NSUInteger globalCount  = mgr.globalEmotes.count;
            NSUInteger channelCount = mgr.channelEmotes.count;

            switch (indexPath.row) {
                case 0:
                    cell.textLabel.text       = @"Channel actuel";
                    cell.detailTextLabel.text = channelName;
                    break;
                case 1:
                    cell.textLabel.text       = @"Emotes globales";
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)globalCount];
                    break;
                case 2:
                    cell.textLabel.text       = @"Emotes du channel";
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)channelCount];
                    break;
                case 3:
                    cell.textLabel.text       = @"Total disponibles";
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu",
                                                 (unsigned long)(globalCount + channelCount)];
                    cell.textLabel.font = [UIFont boldSystemFontOfSize:cell.textLabel.font.pointSize];
                    break;
            }
            return cell;
        }

        // ── Section 2: Logs ────────────────────────────────────────────────
        case 2: {
            switch (indexPath.row) {

                case 0:
                    return [self switchCellWithTitle:@"Logs console (Console.app)"
                                               icon:@"🖥️"
                                               isOn:mgr.debugLogging
                                             action:@selector(toggleDebug:)];

                case 1:
                    return [self switchCellWithTitle:@"Tap logger"
                                               icon:@"👆"
                                               isOn:mgr.tapLogging
                                             action:@selector(toggleTapLog:)];

                case 2: {
                    UITableViewCell *cell = [[UITableViewCell alloc]
                        initWithStyle:UITableViewCellStyleValue1
                       reuseIdentifier:kInfoCell];
                    cell.textLabel.text      = @"🪵  Voir les logs";
                    cell.textLabel.textColor = self.view.tintColor;
                    NSUInteger logCount = [mgr allLogs].count;
                    cell.detailTextLabel.text = logCount > 0
                        ? [NSString stringWithFormat:@"%lu lignes", (unsigned long)logCount]
                        : @"";
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    return cell;
                }

                case 3: {
                    UITableViewCell *cell = [[UITableViewCell alloc]
                        initWithStyle:UITableViewCellStyleDefault
                       reuseIdentifier:kActionCell];
                    cell.textLabel.text      = @"🔄  Recharger les emotes";
                    cell.textLabel.textColor = self.view.tintColor;
                    return cell;
                }

                default:
                    return [[UITableViewCell alloc] init];
            }
        }

        // ── Section 3: À propos ────────────────────────────────────────────
        case 3: {
            UITableViewCell *cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleValue1
               reuseIdentifier:kInfoCell];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            if (indexPath.row == 0) {
                cell.textLabel.text       = @"Version";
                cell.detailTextLabel.text = @"1.0.0";
            } else {
                cell.textLabel.text       = @"API 7TV";
                cell.detailTextLabel.text = @"v3 (7tv.io)";
            }
            return cell;
        }

        default:
            return [[UITableViewCell alloc] init];
    }
}


// ============================================================
// MARK: - Actions sur les cellules
// ============================================================

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 2) {
        if (indexPath.row == 2) [self openLogsViewer];
        if (indexPath.row == 3) [self reloadEmotes];
    }
}

- (void)openLogsViewer {
    SevenTVLogsController *logsVC = [[SevenTVLogsController alloc] init];
    [self.navigationController pushViewController:logsVC animated:YES];
}

- (void)reloadEmotes {
    SevenTVManager *mgr = [SevenTVManager sharedManager];
    [mgr loadGlobalEmotes];
    if (mgr.currentChannelTwitchID) {
        [mgr loadEmotesForChannelTwitchID:mgr.currentChannelTwitchID];
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Rechargement lancé"
                         message:@"Les emotes seront disponibles dans quelques secondes."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleEnabled:(UISwitch *)sw           { [SevenTVManager sharedManager].isEnabled           = sw.isOn; }
- (void)toggleAnimated:(UISwitch *)sw          { [SevenTVManager sharedManager].showAnimated         = sw.isOn; }
- (void)togglePickerAnimations:(UISwitch *)sw  { [SevenTVManager sharedManager].showPickerAnimations = sw.isOn; }
- (void)toggleFloatingButton:(UISwitch *)sw    { [SevenTVManager sharedManager].showFloatingButton   = sw.isOn; }
- (void)toggleDebug:(UISwitch *)sw             { [SevenTVManager sharedManager].debugLogging         = sw.isOn; }
- (void)toggleTapLog:(UISwitch *)sw            { [SevenTVManager sharedManager].tapLogging           = sw.isOn; }


// ============================================================
// MARK: - Helper: cellule avec UISwitch
// ============================================================

- (UITableViewCell *)switchCellWithTitle:(NSString *)title
                                    icon:(NSString *)icon
                                    isOn:(BOOL)isOn
                                  action:(SEL)action {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault
       reuseIdentifier:kSwitchCell];
    cell.textLabel.text = [NSString stringWithFormat:@"%@  %@", icon, title];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = isOn;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

@end
