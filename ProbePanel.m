#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSMutableArray<NSDictionary *> *SXEntries;
static dispatch_queue_t SXQueue;
static BOOL SXEnabled = NO;

static void SXRecord(NSString *event, NSDictionary *fields) {
    if (!SXEnabled || !SXQueue) return;
    NSDictionary *item = @{@"event":event ?: @"unknown",
                           @"timestamp":@([[NSDate date] timeIntervalSince1970]),
                           @"fields":fields ?: @{}};
    dispatch_async(SXQueue, ^{
        [SXEntries addObject:item];
        if (SXEntries.count > 300) [SXEntries removeObjectsInRange:NSMakeRange(0, SXEntries.count - 300)];
    });
}

@interface SXProbePanel : UITableViewController
@end

@implementation SXProbePanel
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SX Probe";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closePanel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"共有" style:UIBarButtonItemStylePlain target:self action:@selector(exportJSON)];
}
- (void)closePanel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 3 : 2; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSBundle *bundle = [NSBundle mainBundle];
    if (path.section == 0) {
        if (path.row == 0) {
            cell.textLabel.text = @"X バージョン";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)", [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?", [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
        } else if (path.row == 1) {
            cell.textLabel.text = @"クラス存在チェック";
            NSUInteger count = 0;
            const char *targets[] = {"TTAStatusBodyTextView", "T1StatusCell", "T1StandardStatusView", "T1StatusTableRowAdapter"};
            for (NSUInteger i = 0; i < 4; i++) if (objc_getClass(targets[i])) count++;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu / 4", (unsigned long)count];
        } else {
            cell.textLabel.text = @"メタデータ記録";
            UISwitch *toggle = [UISwitch new];
            toggle.on = SXEnabled;
            [toggle addTarget:self action:@selector(toggleRecording:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
        }
    } else {
        if (path.row == 0) {
            cell.textLabel.text = @"診断JSONを共有";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else {
            cell.textLabel.text = @"診断ログを消去";
            cell.textLabel.textColor = UIColor.systemRedColor;
        }
    }
    return cell;
}
- (void)toggleRecording:(UISwitch *)sender {
    SXEnabled = sender.isOn;
    if (SXEnabled) {
        NSBundle *b = NSBundle.mainBundle;
        SXRecord(@"probe-enabled", @{@"version":[b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown"});
        const char *names[] = {"TTAStatusBodyTextView", "T1StatusCell", "T1StandardStatusView", "T1StatusTableRowAdapter"};
        for (NSUInteger i = 0; i < 4; ++i)
            SXRecord(@"class-check", @{@"class":[NSString stringWithUTF8String:names[i]], @"present":@(objc_getClass(names[i]) != nil)});
    }
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section != 1) return;
    if (path.row == 0) [self exportJSON];
    if (path.row == 1) {
        dispatch_sync(SXQueue, ^{ [SXEntries removeAllObjects]; });
        [self.tableView reloadData];
    }
}
- (void)exportJSON {
    __block NSArray *entries;
    dispatch_sync(SXQueue, ^{ entries = [SXEntries copy]; });
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *payload = @{
        @"format":@"ScarletXProbe",
        @"schemaVersion":@1,
        @"generatedAt":@([[NSDate date] timeIntervalSince1970]),
        @"xVersion":[bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
        @"xBuild":[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
        @"entries":entries ?: @[]
    };
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:&error];
    if (!json) return;
    NSString *filename = [NSString stringWithFormat:@"SXProbe_%lld.json", (long long)[NSDate.date timeIntervalSince1970]];
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];
    if (![json writeToURL:url atomically:YES]) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:share animated:YES completion:nil];
}
@end

// Temporary opt-in diagnostic entry point for validating the panel on X 12.35.
// No X-private menu classes are modified. Actual side-menu integration follows
// after native menu classes have been observed on the installed app.
static NSArray<UIWindow *> *SXProbeWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    return windows;
}
static void SXOpenPanel(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ SXOpenPanel(); }); return; }
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.atebits.Tweetie2"]) return;
    UIWindow *window = nil;
    for (UIWindow *w in SXProbeWindows()) {
        if (w.isKeyWindow) { window = w; break; }
    }
    UIViewController *current = window.rootViewController;
    if (!current) return;
    while (current.presentedViewController) current = current.presentedViewController;
    if ([current isKindOfClass:UINavigationController.class] && [[(UINavigationController *)current topViewController] isKindOfClass:SXProbePanel.class]) return;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[SXProbePanel new]];
    [current presentViewController:nav animated:YES completion:nil];
}
@interface SXProbeGestureTarget : NSObject
@end
@implementation SXProbeGestureTarget
- (void)trigger:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) SXOpenPanel();
}
- (void)openFromButton:(__unused UIButton *)sender { SXOpenPanel(); }
@end
static SXProbeGestureTarget *SXGestureTarget;
static char SXInstalledEntryKey;
static void SXInstallTemporaryEntry(void) {
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.atebits.Tweetie2"]) return;
    if (!SXGestureTarget) SXGestureTarget = [SXProbeGestureTarget new];
    for (UIWindow *w in SXProbeWindows()) {
        if (!w.isKeyWindow || !w.rootViewController) continue;
        if (objc_getAssociatedObject(w, &SXInstalledEntryKey)) continue;
        // Visible temporary entry proves that the dylib loaded into official X.
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(12, 110, 92, 32);
        button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        [button setTitle:@"SX Probe" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        button.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.90];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.layer.cornerRadius = 8;
        [button addTarget:SXGestureTarget action:@selector(openFromButton:) forControlEvents:UIControlEventTouchUpInside];
        [w addSubview:button];
        objc_setAssociatedObject(w, &SXInstalledEntryKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
__attribute__((constructor))
static void SXProbeInit(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.atebits.Tweetie2"]) return;
        SXQueue = dispatch_queue_create("com.botanium.sxprobe.entries", DISPATCH_QUEUE_SERIAL);
        SXEntries = [NSMutableArray new];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                SXInstallTemporaryEntry();
            }];
            SXInstallTemporaryEntry();
        });
            [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                SXInstallTemporaryEntry();
            }];
    }
}
