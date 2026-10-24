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
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 5; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray *titles = @[@"GitHubトークンを登録", @"最新ビルドを確認", @"成果物ZIPを取得・共有", @"GitHubトークンを削除", @"現在の状態"];
    c.textLabel.text = titles[p.row];
    if (p.row == 0) c.detailTextLabel.text = SXUpdateToken().length ? @"Keychainに登録済み" : @"未登録";
    if (p.row == 1) c.detailTextLabel.text = @"非公開develop / 成功したpushのみ";
    if (p.row == 2) c.detailTextLabel.text = @"ダウンロード後にFilzaで展開・確認";
    if (p.row == 3) c.detailTextLabel.text = @"端末内の認証情報だけを削除";
    if (p.row == 4) c.detailTextLabel.text = self.statusText;
    c.detailTextLabel.numberOfLines = 0;
    c.accessoryType = p.row <= 3 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
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
        [self downloadArtifact];
    } else if (p.row == 3) {
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

- (void)downloadArtifact {
    NSString *token=SXUpdateToken();
    if (!token.length) { [self alert:@"未設定" message:@"先にGitHubトークンを登録してね。"]; return; }
    self.busy=YES; [self setStatus:@"非公開Actionsの成果物を確認中…"];
    __weak typeof(self) weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSString *base=[NSString stringWithFormat:@"https://api.github.com/repos/%@",SXUpdateRepo];
        __block NSError *failure=nil;
        __block NSURL *saved=nil;
        NSString *message=nil;
        @try {
            NSDictionary *runs=[self updateJSON:[base stringByAppendingString:@"/actions/workflows/build.yml/runs?branch=develop&event=push&status=success&per_page=20"] token:token error:&failure];
            NSDictionary *best=nil;
            for(NSDictionary *r in runs[@"workflow_runs"]) {
                if (![r isKindOfClass:NSDictionary.class] || ![r[@"head_branch"] isEqual:@"develop"] ||
                    ![r[@"event"] isEqual:@"push"] || ![r[@"status"] isEqual:@"completed"] ||
                    ![r[@"conclusion"] isEqual:@"success"] || ![r[@"path"] hasSuffix:@"build.yml"]) continue;
                if(!best || [r[@"id"] longLongValue]>[best[@"id"] longLongValue])best=r;
            }
            if(!failure && !best)failure=[NSError errorWithDomain:@"SXUpdate" code:1 userInfo:@{NSLocalizedDescriptionKey:@"成功ビルドがない"}];
            NSDictionary *artifactList=!failure?[self updateJSON:[NSString stringWithFormat:@"%@/actions/runs/%@/artifacts?per_page=100",base,best[@"id"]] token:token error:&failure]:nil;
            NSDictionary *artifact=nil; NSInteger count=0;
            for(NSDictionary *a in artifactList[@"artifacts"]) {
                if([a isKindOfClass:NSDictionary.class] && [a[@"name"] isEqual:@"SCARLET-X-Probe-roothide"] && ![a[@"expired"] boolValue]) {artifact=a;count++;}
            }
            if(!failure && count!=1)failure=[NSError errorWithDomain:@"SXUpdate" code:2 userInfo:@{NSLocalizedDescriptionKey:@"有効な成果物が1つに決まらない"}];
            NSHTTPURLResponse *redirect=nil;
            if(!failure)[self updateFetch:[NSString stringWithFormat:@"%@/actions/artifacts/%@/zip",base,artifact[@"id"]] token:token maximum:2048 response:&redirect error:&failure];
            NSString *signedURL=nil;
            if(!failure) {
                for(id key in redirect.allHeaderFields)if([[key description] caseInsensitiveCompare:@"Location"]==NSOrderedSame)signedURL=[redirect.allHeaderFields[key] description];
                NSURLComponents *c=[NSURLComponents componentsWithString:signedURL];
                if(redirect.statusCode!=302 || ![c.scheme isEqual:@"https"] || !c.host.length || c.user || c.password) {
                    failure=[NSError errorWithDomain:@"SXUpdate" code:3 userInfo:@{NSLocalizedDescriptionKey:@"GitHubの配布URLが不正"}];
                }
            }
            NSHTTPURLResponse *zipResponse=nil;
            NSData *zip=!failure?[self updateFetch:signedURL token:nil maximum:33554432 response:&zipResponse error:&failure]:nil;
            if(!failure && (zipResponse.statusCode!=200 || zip.length<22 || memcmp(zip.bytes,(const unsigned char[]){0x50,0x4b,0x03,0x04},4)!=0))
                failure=[NSError errorWithDomain:@"SXUpdate" code:4 userInfo:@{NSLocalizedDescriptionKey:@"ZIPの受信・形式確認に失敗"}];
            if(!failure) {
                NSString *name=[NSString stringWithFormat:@"SXProbe-build-%@.zip",best[@"id"]];
                NSURL *dir=[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
                saved=[dir URLByAppendingPathComponent:name];
                if(![zip writeToURL:saved options:NSDataWritingAtomic error:&failure])saved=nil;
            }
            if(!failure) message=@"✅ 非公開ZIPの取得成功。Filzaで解凍し、debを確認してからインストールしてね。";
        } @catch(NSException *e) {
            failure=[NSError errorWithDomain:@"SXUpdate" code:5 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"取得処理の例外: %@",e.name]}];
        }
        if(!message)message=[NSString stringWithFormat:@"❌ 取得失敗: %@",failure.localizedDescription?:@"不明なエラー"];
        dispatch_async(dispatch_get_main_queue(),^{
            __strong typeof(weakSelf) strong=weakSelf;
            if(!strong)return;
            strong.busy=NO;[strong setStatus:message];
            if(saved) {
                UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[saved] applicationActivities:nil];
                share.popoverPresentationController.sourceView=strong.view;
                share.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(strong.view.bounds),20,1,1);
                [strong presentViewController:share animated:YES completion:nil];
            }
        });
    });
}
- (NSData *)updateFetch:(NSString *)url token:(NSString *)token maximum:(NSUInteger)maximum response:(NSHTTPURLResponse **)response error:(NSError **)error {
    NSURLComponents *c=[NSURLComponents componentsWithString:url];
    if(![c.scheme isEqual:@"https"] || !c.host.length || c.user || c.password || (token && ![c.host isEqual:@"api.github.com"])) {
        if(error)*error=[NSError errorWithDomain:@"SXUpdate" code:10 userInfo:@{NSLocalizedDescriptionKey:@"不正な接続先"}]; return nil;
    }
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:c.URL];
    r.timeoutInterval=40;
    [r setValue:@"SCARLET-X-Probe-updater" forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    if(token)[r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration delegate:[SXNoCredentialRedirect new] delegateQueue:nil];
    dispatch_semaphore_t sem=dispatch_semaphore_create(0);
    __block NSData *body=nil;__block NSError *failure=nil;__block NSURLResponse *res=nil;
    NSURLSessionDataTask *task=[session dataTaskWithRequest:r completionHandler:^(NSData *d,NSURLResponse *resp,NSError *e){body=d;res=resp;failure=e;dispatch_semaphore_signal(sem);}];
    [task resume];
    if(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,65*NSEC_PER_SEC))) { [task cancel];failure=[NSError errorWithDomain:@"SXUpdate" code:11 userInfo:@{NSLocalizedDescriptionKey:@"通信タイムアウト"}]; }
    [session invalidateAndCancel];
    if(response)*response=[res isKindOfClass:NSHTTPURLResponse.class]?(NSHTTPURLResponse *)res:nil;
    if(body.length>maximum)failure=[NSError errorWithDomain:@"SXUpdate" code:12 userInfo:@{NSLocalizedDescriptionKey:@"取得ファイルが大きすぎる"}];
    if(error)*error=failure;
    return failure?nil:body;
}
- (NSDictionary *)updateJSON:(NSString *)url token:(NSString *)token error:(NSError **)error {
    NSHTTPURLResponse *response=nil;
    NSData *d=[self updateFetch:url token:token maximum:2097152 response:&response error:error];
    if(!d)return nil;
    if(response.statusCode!=200) {
        if(error)*error=[NSError errorWithDomain:@"SXUpdate" code:response.statusCode userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"GitHub HTTP %ld",(long)response.statusCode]}];return nil;
    }
    id obj=[NSJSONSerialization JSONObjectWithData:d options:0 error:error];
    return [obj isKindOfClass:NSDictionary.class]?obj:nil;
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
