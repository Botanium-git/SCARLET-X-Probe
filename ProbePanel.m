#import <UIKit/UIKit.h>
#import <objc/runtime.h>
extern BOOL SXDriveIsConnected(void);
extern NSString *SXDriveCurrentStatus(void);
extern void SXDriveHandleRow(NSInteger row, UIViewController *host);

static NSMutableArray<NSDictionary *> *SXEntries;
static dispatch_queue_t SXQueue;
static BOOL SXEnabled = NO;
static NSString * const SXRecordingKey = @"com.botanium.sxprobe.metadata.enabled";

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

NSDictionary *SXProbeDiagnosticPayload(void) {
    __block NSArray *entries=nil;
    if(SXQueue) dispatch_sync(SXQueue, ^{ entries=[SXEntries copy]; });
    NSBundle *b=NSBundle.mainBundle;
    return @{@"format":@"ScarletXProbe",@"schemaVersion":@1,
             @"generatedAt":@(NSDate.date.timeIntervalSince1970),
             @"xVersion":[b objectForInfoDictionaryKey:@"CFBundleShortVersionString"]?:@"",
             @"xBuild":[b objectForInfoDictionaryKey:@"CFBundleVersion"]?:@"",
             @"entries":entries?:@[]};
}

@interface SXProbePanel : UITableViewController
@end

@implementation SXProbePanel
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SX Probe";
    SXEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:SXRecordingKey];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(driveUpdated:) name:@"SXDriveStateChanged" object:nil];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closePanel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"共有" style:UIBarButtonItemStylePlain target:self action:@selector(exportJSON)];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)driveUpdated:(NSNotification *)note { [self.tableView reloadData]; }
- (void)closePanel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 3; }
- (NSInteger)rowForPath:(NSIndexPath *)path { return path.section * 3 + path.row; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSBundle *bundle = [NSBundle mainBundle];
    NSInteger row = [self rowForPath:path];
    if (row <= 2) {
        if (row == 0) {
            cell.textLabel.text = @"X バージョン";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)", [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?", [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?"];
        } else if (row == 1) {
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
    } else if (row == 3) {
        cell.textLabel.text=SXDriveIsConnected()?@"接続を解除":@"Googleアカウントで接続";
        cell.detailTextLabel.text=SXDriveIsConnected()?@"接続済み":@"未接続";
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if (row == 4) {
        cell.textLabel.text=@"診断JSONをDriveへ送信";
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if (row == 5) {
        cell.textLabel.text=@"現在の状態";
        cell.detailTextLabel.text=SXDriveCurrentStatus();
    } else if (row == 6) {
        cell.textLabel.text=@"クラスメソッド情報を記録";
        cell.detailTextLabel.text=@"読み取り専用";
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if (row == 7) {
        cell.textLabel.text=@"診断JSONを共有";
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else if (row == 8) {
        cell.textLabel.text=@"診断ログを消去";
        cell.textLabel.textColor=UIColor.systemRedColor;
    }
    return cell;
}
- (void)toggleRecording:(UISwitch *)sender {
    SXEnabled = sender.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:SXEnabled forKey:SXRecordingKey];
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
    NSInteger row = [self rowForPath:path];
    if (row == 3 || row == 4) SXDriveHandleRow(row - 3,self);
    if (row == 6) [self recordMethodMetadata];
    if (row == 7) [self exportJSON];
    if (row == 8) { dispatch_sync(SXQueue, ^{ [SXEntries removeAllObjects]; }); [self.tableView reloadData]; }
}
- (void)recordMethodMetadata {
 if(!SXEnabled) {
  UIAlertController *a=[UIAlertController alertControllerWithTitle:@"メタデータ記録がオフ" message:@"先にメタデータ記録をオンにしてね。" preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
  [self presentViewController:a animated:YES completion:nil];return;
 }
 const char *names[]={"TTAStatusBodyTextView","T1StatusCell","T1StandardStatusView","T1StatusTableRowAdapter"};
 NSArray *terms=@[@"height",@"size",@"layout",@"display",@"text",@"row",@"status",@"viewmodel",@"frame",@"font"];
 for(NSUInteger i=0;i<4;i++){
  Class cls=objc_getClass(names[i]);if(!cls)continue;
  unsigned int count=0;Method *methods=class_copyMethodList(cls,&count);
  NSMutableArray *selected=[NSMutableArray array];
  for(unsigned int j=0;j<count;j++){
   const char *cname=sel_getName(method_getName(methods[j]));if(!cname)continue;
   NSString *name=[NSString stringWithUTF8String:cname],*lower=name.lowercaseString;
   for(NSString *term in terms){if([lower containsString:term]){if(selected.count<60)[selected addObject:name];break;}}
  }
  if(methods)free(methods);
  SXRecord(@"method-names",@{@"class":[NSString stringWithUTF8String:names[i]],@"instanceMethodCount":@(count),@"matchingSelectors":selected});
 }
 UIAlertController *a=[UIAlertController alertControllerWithTitle:@"記録完了" message:@"4クラスの関連メソッド名を記録したわ。Driveへ送信してね。" preferredStyle:UIAlertControllerStyleAlert];
 [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
 [self presentViewController:a animated:YES completion:nil];
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
        button.frame = CGRectMake(104, 26, 42, 32);
        button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        [button setTitle:@"SX" forState:UIControlStateNormal];
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
