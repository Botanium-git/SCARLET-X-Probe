#import <UIKit/UIKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

// Experimental OAuth return-path test only. No tokens are persisted or uploaded.
// X's Info.plist, URL schemes, credentials and app data are never modified.
static NSString * const SXClientID = @"336218902468-g2t9ha7h9jhfckilh1l8k2k1gl64sltr.apps.googleusercontent.com";
static NSString * const SXCallbackScheme = @"com.googleusercontent.apps.336218902468-g2t9ha7h9jhfckilh1l8k2k1gl64sltr";
static NSString *SXEncoded(NSData *data) {
    NSString *s = [data base64EncodedStringWithOptions:0];
    return [[[s stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
             stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
            stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
static NSString *SXNonce(NSUInteger bytes) {
    NSMutableData *data = [NSMutableData dataWithLength:bytes];
    return SecRandomCopyBytes(kSecRandomDefault, bytes, data.mutableBytes) == errSecSuccess ? SXEncoded(data) : nil;
}
@interface SXProbeOAuthTest : UITableViewController <ASWebAuthenticationPresentationContextProviding>
@property(nonatomic,strong) ASWebAuthenticationSession *auth;
@property(nonatomic,copy) NSString *expectedState;
@property(nonatomic,copy) NSString *statusText;
@end
@implementation SXProbeOAuthTest
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"Drive認証テスト";
    self.statusText=@"未実行";
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 2; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)p {
    UITableViewCell *c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.textLabel.text=p.row==0?@"Googleログインを試す":@"現在の結果";
    c.detailTextLabel.text=p.row==0?@"認証結果は保存せず、Drive送信もしません":self.statusText;
    c.detailTextLabel.numberOfLines=0;
    c.accessoryType=p.row==0?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone;
    return c;
}
- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return self.view.window;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)p {
    [tableView deselectRowAtIndexPath:p animated:YES];
    if(p.row!=0 || self.auth) return;
    NSString *verifier=SXNonce(32),*state=SXNonce(24);
    if(!verifier.length||!state.length){self.statusText=@"乱数生成に失敗";[self.tableView reloadData];return;}
    NSData *v=[verifier dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(v.bytes,(CC_LONG)v.length,hash);
    NSString *redirect=[NSString stringWithFormat:@"%@:/oauth2redirect/google",SXCallbackScheme];
    NSURLComponents *url=[NSURLComponents componentsWithString:@"https://accounts.google.com/o/oauth2/v2/auth"];
    url.queryItems=@[
        [NSURLQueryItem queryItemWithName:@"client_id" value:SXClientID],
        [NSURLQueryItem queryItemWithName:@"redirect_uri" value:redirect],
        [NSURLQueryItem queryItemWithName:@"response_type" value:@"code"],
        [NSURLQueryItem queryItemWithName:@"scope" value:@"https://www.googleapis.com/auth/drive.file"],
        [NSURLQueryItem queryItemWithName:@"code_challenge" value:SXEncoded([NSData dataWithBytes:hash length:sizeof(hash)])],
        [NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
        [NSURLQueryItem queryItemWithName:@"state" value:state]
    ];
    self.expectedState=state;
    self.statusText=@"認証画面を起動中…";
    [self.tableView reloadData];
    __weak typeof(self) weakSelf=self;
    self.auth=[[ASWebAuthenticationSession alloc] initWithURL:url.URL callbackURLScheme:SXCallbackScheme completionHandler:^(NSURL *callback,NSError *error){
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self=weakSelf;if(!self)return;
            self.auth=nil;
            if(error){self.statusText=[NSString stringWithFormat:@"戻り失敗: %@ (%ld)",error.domain,(long)error.code];}
            else {
                NSURLComponents *parts=[NSURLComponents componentsWithURL:callback resolvingAgainstBaseURL:NO];
                NSString *gotState=nil,*code=nil,*oauthError=nil;
                for(NSURLQueryItem *item in parts.queryItems) {
                    if([item.name isEqualToString:@"state"])gotState=item.value;
                    if([item.name isEqualToString:@"code"])code=item.value;
                    if([item.name isEqualToString:@"error"])oauthError=item.value;
                }
                if(![callback.scheme isEqualToString:SXCallbackScheme] || ![gotState isEqualToString:self.expectedState])
                    self.statusText=@"認証応答の検証に失敗";
                else if(oauthError.length) self.statusText=[@"Google認証エラー: " stringByAppendingString:oauthError];
                else if(code.length) self.statusText=@"認証コードの受信成功（保存・交換せず破棄）";
                else self.statusText=@"戻りは受信したが認証コードなし";
            }
            self.expectedState=nil;
            [self.tableView reloadData];
        });
    }];
    self.auth.presentationContextProvider=self;
    if(![self.auth start]){
        self.auth=nil;self.expectedState=nil;self.statusText=@"認証セッションを開始できません";
        [self.tableView reloadData];
    }
}
@end
UIViewController *SXCreateProbeOAuthTestController(void) { return [SXProbeOAuthTest new]; }
