#import <UIKit/UIKit.h>
#import <Security/Security.h>

// Stage 1: private GitHub credentials and read-only update discovery.
// Deliberately does not download, extract, install or run privileged commands.
// Runs inside the official X app process, so its Keychain access is under X's
// effective app identity. Never collect credentials into diagnostic JSON.
static NSString * const SXUpdateService = @"com.botanium.scarletxprobe.github.actions";
static NSString * const SXUpdateAccount = @"private-actions-read";
static NSString * const SXUpdateRepo = @"Botanium-git/SCARLET-X-Probe";

static NSMutableDictionary *SXUpdateKeyQuery(void) {
    return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService:SXUpdateService,
              (__bridge id)kSecAttrAccount:SXUpdateAccount} mutableCopy];
}
static NSString *SXUpdateToken(void) {
    NSMutableDictionary *q = SXUpdateKeyQuery();
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef output = NULL;
    OSStatus rc = SecItemCopyMatching((__bridge CFDictionaryRef)q, &output);
    if (rc != errSecSuccess || !output) return nil;
    NSData *d = CFBridgingRelease(output);
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}
static BOOL SXUpdateSaveToken(NSString *token) {
    NSData *d = [token dataUsingEncoding:NSUTF8StringEncoding];
    if (!d.length) return NO;
    NSMutableDictionary *q = SXUpdateKeyQuery();
    SecItemDelete((__bridge CFDictionaryRef)q);
    q[(__bridge id)kSecValueData] = d;
    q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    return SecItemAdd((__bridge CFDictionaryRef)q, NULL) == errSecSuccess;
}
static BOOL SXUpdateDeleteToken(void) {
    OSStatus rc = SecItemDelete((__bridge CFDictionaryRef)SXUpdateKeyQuery());
    return rc == errSecSuccess || rc == errSecItemNotFound;
}

@interface SXNoCredentialRedirect : NSObject <NSURLSessionTaskDelegate>
@end
@implementation SXNoCredentialRedirect
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    completionHandler(nil);
}
@end

@interface SXPrivateUpdater : UITableViewController
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic,assign) BOOL busy;
@end

@implementation SXPrivateUpdater
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Probe更新（準備中）";
    self.statusText = @"GitHub認証の設定と最新版の確認に対応。インストールは未対応。";
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 4; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray *titles = @[@"GitHubトークンを登録", @"最新ビルドを確認", @"GitHubトークンを削除", @"現在の状態"];
    c.textLabel.text = titles[p.row];
    if (p.row == 0) c.detailTextLabel.text = SXUpdateToken().length ? @"Keychainに登録済み" : @"未登録";
    if (p.row == 1) c.detailTextLabel.text = @"非公開develop / 成功したpushのみ";
    if (p.row == 2) c.detailTextLabel.text = @"端末内の認証情報だけを削除";
    if (p.row == 3) c.detailTextLabel.text = self.statusText;
    c.detailTextLabel.numberOfLines = 0;
    c.accessoryType = p.row <= 2 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return c;
}
- (void)setStatus:(NSString *)message {
    self.statusText = message;
    [self.tableView reloadData];
}
- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)p {
    [tableView deselectRowAtIndexPath:p animated:YES];
    if (self.busy) return;
    if (p.row == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"GitHub認証"
            message:@"SCARLET-X-ProbeのみにActions: Read / Contents: Readを許可した期限付きトークンを入力。公式Xのアプリ領域のKeychainに保存されます。"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"github_pat_...";
            field.secureTextEntry = YES;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        __weak typeof(self) weakSelf = self;
        [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            NSString *token = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!token.length || [token containsString:@"\n"]) { [self alert:@"保存できません" message:@"トークンを確認してね。"]; return; }
            [self setStatus:SXUpdateSaveToken(token) ? @"✅ Keychainに保存しました（API認証は未検証）" : @"❌ Keychainへの保存に失敗"];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    } else if (p.row == 1) {
        [self checkLatest];
    } else if (p.row == 2) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"トークンを削除？" message:@"次回の確認には再登録が必要になるわ。" preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [a addAction:[UIAlertAction actionWithTitle:@"削除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            if (self) [self setStatus:SXUpdateDeleteToken() ? @"✅ Keychainから削除しました" : @"❌ 削除できませんでした"];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    }
}
- (void)checkLatest {
    NSString *token = SXUpdateToken();
    if (!token.length) { [self alert:@"未設定" message:@"先にGitHubトークンを登録してね。"]; return; }
    self.busy = YES;
    [self setStatus:@"GitHub Actionsを確認中…"];
    NSString *u = [NSString stringWithFormat:@"https://api.github.com/repos/%@/actions/workflows/build.yml/runs?branch=develop&event=push&status=success&per_page=20", SXUpdateRepo];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]];
    r.timeoutInterval = 30;
    [r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [r setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];
    [r setValue:@"SCARLET-X-Probe-updater" forHTTPHeaderField:@"User-Agent"];
    // Prevent credentialed redirects to untrusted hosts.
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:[SXNoCredentialRedirect new] delegateQueue:nil];
    __weak typeof(self) weakSelf = self;
    [[session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *runs = [json isKindOfClass:NSDictionary.class] && [json[@"workflow_runs"] isKindOfClass:NSArray.class] ? json[@"workflow_runs"] : @[];
        NSDictionary *best = nil;
        for (id item in runs) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            if (![item[@"head_branch"] isEqual:@"develop"] || ![item[@"event"] isEqual:@"push"] ||
                ![item[@"conclusion"] isEqual:@"success"] || ![item[@"status"] isEqual:@"completed"]) continue;
            if (![item[@"path"] isKindOfClass:NSString.class] || ![item[@"path"] hasSuffix:@"build.yml"]) continue;
            if (!best || [item[@"id"] longLongValue] > [best[@"id"] longLongValue]) best = item;
        }
        NSString *message;
        if (error) message = [NSString stringWithFormat:@"❌ 通信エラー: %@", error.localizedDescription];
        else if (code != 200) message = [NSString stringWithFormat:@"❌ GitHub API HTTP %ld", (long)code];
        else if (!best) message = @"⚠️ 成功したdevelopのpushビルドが見つからない";
        else message = [NSString stringWithFormat:@"✅ ビルド確認済み: %@ / commit %@（ダウンロード・更新は未実装）",
                      best[@"id"] ?: @"?", [best[@"head_sha"] isKindOfClass:NSString.class] ? [best[@"head_sha"] substringToIndex:MIN((NSUInteger)12, [best[@"head_sha"] length])] : @"?"];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self) { self.busy = NO; [self setStatus:message]; }
        });
        [session finishTasksAndInvalidate];
    }] resume];
}
@end

void SXOpenPrivateUpdater(UIViewController *host) {
    if (!host) return;
    SXPrivateUpdater *vc = [SXPrivateUpdater new];
    [host.navigationController pushViewController:vc animated:YES];
}
