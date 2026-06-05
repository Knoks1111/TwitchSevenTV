/*
 * SevenTVSettingsController.m
 *
 * Interface de paramètres native iOS (UITableViewController).
 * Accessible via le bouton flottant "7TV" dans l'app Twitch.
 *
 * Sections:
 *   1. Activation générale de 7TV
 *   2. Options d'affichage (emotes animées)
 *   3. Informations (version, channel actuel, nb d'emotes)
 *   4. Débogage (logs console, voir logs in-app, recharger)
 *   5. À propos
 */

#import "SevenTVSettingsController.h"
#import "SevenTVManager.h"
#import "SevenTVLogsController.h"

// Identifiants des cellules
static NSString *const kSwitchCell = @"SwitchCell";
static NSString *const kInfoCell   = @"InfoCell";
static NSString *const kActionCell = @"ActionCell";

@interface SevenTVSettingsController ()
// Pour rafraîchir les infos dynamiquement
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

    // Bouton "Fermer"
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
    // Recharger uniquement la section d'infos (section 2)
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                  withRowAnimation:UITableViewRowAnimationNone];
}


// ============================================================
// MARK: - Structure du tableau (sections et cellules)
// ============================================================

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 5;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Général";
        case 1: return @"Affichage";
        case 2: return @"Statistiques";
        case 3: return @"Débogage";
        case 4: return @"À propos";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Désactiver 7TV ne supprime pas les emotes déjà affichées.";
        case 1: return @"Les emotes animées (GIF) consomment un peu plus de batterie.";
        case 3: return @"Le buffer conserve les 1000 dernières lignes. "
                       @"Activer \"Logs console\" pour voir aussi dans Console.app (Mac requis).";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1; // Activer 7TV
        case 1: return 1; // Emotes animées
        case 2: return 4; // Stats: channel, global, channel emotes, total
        case 3: return 4; // Logs console + Tap logger + Voir les logs + Recharger emotes
        case 4: return 2; // Version + Info API
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    SevenTVManager *mgr = [SevenTVManager sharedManager];

    switch (indexPath.section) {

        // ── Section 0: Activation ──
        case 0: {
            UITableViewCell *cell = [self switchCellWithTitle:@"Activer 7TV"
                                                         icon:@"🟣"
                                                       isOn:mgr.isEnabled
                                                       action:@selector(toggleEnabled:)];
            return cell;
        }

        // ── Section 1: Affichage ──
        case 1: {
            UITableViewCell *cell = [self switchCellWithTitle:@"Emotes animées"
                                                         icon:@"✨"
                                                       isOn:mgr.showAnimated
                                                       action:@selector(toggleAnimated:)];
            return cell;
        }

        // ── Section 2: Stats ──
        case 2: {
            UITableViewCell *cell = [[UITableViewCell alloc]
                initWithStyle:UITableViewCellStyleValue1
               reuseIdentifier:kInfoCell];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;

            NSString *channelName = mgr.currentChannelName ?: @"Aucun";
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
                    cell.textLabel.font       = [UIFont boldSystemFontOfSize:cell.textLabel.font.pointSize];
                    break;
            }
            return cell;
        }

        // ── Section 3: Debug ──
        case 3: {
            switch (indexPath.row) {

                // Ligne 0: toggle logs console (NSLog / Console.app)
                case 0: {
                    UITableViewCell *cell = [self switchCellWithTitle:@"Logs console (NSLog)"
                                                                 icon:@"🖥️"
                                                               isOn:mgr.debugLogging
                                                               action:@selector(toggleDebug:)];
                    return cell;
                }

                // Ligne 1: toggle tap logger (log hiérarchie à chaque tap)
                case 1: {
                    // s_tapLogEnabled est défini dans TweakSevenTV.m
                    extern BOOL s_tapLogEnabled;
                    UITableViewCell *cell = [self switchCellWithTitle:@"Tap logger (log chaque tap)"
                                                                 icon:@"👆"
                                                               isOn:s_tapLogEnabled
                                                               action:@selector(toggleTapLogger:)];
                    return cell;
                }

                // Ligne 2: ouvrir le viewer de logs in-app
                case 2: {
                    UITableViewCell *cell = [[UITableViewCell alloc]
                        initWithStyle:UITableViewCellStyleValue1
                       reuseIdentifier:kInfoCell];

                    cell.textLabel.text      = @"🪵  Voir les logs";
                    cell.textLabel.textColor = self.view.tintColor;

                    NSUInteger logCount = [[SevenTVManager sharedManager] allLogs].count;
                    cell.detailTextLabel.text = logCount > 0
                        ? [NSString stringWithFormat:@"%lu lignes", (unsigned long)logCount]
                        : @"";

                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    return cell;
                }

                // Ligne 3: recharger les emotes
                case 3: {
                    UITableViewCell *cell = [[UITableViewCell alloc]
                        initWithStyle:UITableViewCellStyleDefault
                       reuseIdentifier:kActionCell];
                    cell.textLabel.text      = @"🔄  Recharger les emotes";
                    cell.textLabel.textColor = self.view.tintColor;
                    cell.accessoryType       = UITableViewCellAccessoryNone;
                    return cell;
                }

                default:
                    return [[UITableViewCell alloc] init];
            }
        }

        // ── Section 4: À propos ──
        case 4: {
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

    if (indexPath.section == 3) {
        switch (indexPath.row) {
            case 2: // "Voir les logs"
                [self openLogsViewer];
                break;
            case 3: // "Recharger les emotes"
                [self reloadEmotes];
                break;
        }
    }
}

// Ouvre SevenTVLogsController en push dans la navigation courante
- (void)openLogsViewer {
    SevenTVLogsController *logsVC = [[SevenTVLogsController alloc] init];
    [self.navigationController pushViewController:logsVC animated:YES];
}

- (void)reloadEmotes {
    SevenTVManager *mgr = [SevenTVManager sharedManager];

    // Vider le cache et recharger
    [mgr loadGlobalEmotes];
    if (mgr.currentChannelTwitchID) {
        [mgr loadEmotesForChannelTwitchID:mgr.currentChannelTwitchID];
    }

    // Feedback visuel
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Rechargement lancé"
                         message:@"Les emotes seront disponibles dans quelques secondes."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Toggles
- (void)toggleEnabled:(UISwitch *)sw {
    [SevenTVManager sharedManager].isEnabled = sw.isOn;
}
- (void)toggleAnimated:(UISwitch *)sw {
    [SevenTVManager sharedManager].showAnimated = sw.isOn;
}
- (void)toggleDebug:(UISwitch *)sw {
    [SevenTVManager sharedManager].debugLogging = sw.isOn;
}
- (void)toggleTapLogger:(UISwitch *)sw {
    extern BOOL s_tapLogEnabled;
    s_tapLogEnabled = sw.isOn;
    [[SevenTVManager sharedManager] log:@"👆 Tap logger %@", sw.isOn ? @"activé" : @"désactivé"];
}


// ============================================================
// MARK: - Helper: créer une cellule avec UISwitch
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
