import UIKit
import WebKit
import Compression

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.backgroundColor = .white
        w.rootViewController = RootViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

// =====================================================================
// MARK: - 主界面（托管整页 HTML）
// =====================================================================
final class RootViewController: UIViewController, WKScriptMessageHandler {

    static let docURL = URL(string: "https://docs.qq.com/sheet/DWkdWamR2bExXUWtC?tab=000002")!
    private static let docId = "DWkdWamR2bExXUWtC"
    private static let tab = "000002"

    private var web: WKWebView!
    private var loginVC: LoginViewController?
    private var running = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.userContentController.add(self, name: "FlymeDoc")
        let shim = """
        (function(){
          if(!window.webkit||!window.webkit.messageHandlers||!window.webkit.messageHandlers.FlymeDoc) return;
          function post(action, extra){
            var msg = {action: action};
            if (extra) for (var k in extra) msg[k] = extra[k];
            window.webkit.messageHandlers.FlymeDoc.postMessage(msg);
          }
          window.flymeDoc = {
            fetchUrls: function(ids){ return new Promise(function(res, rej){
              window.__flymeDocResolve = res; window.__flymeDocReject = rej;
              try { post('fetchUrls', {ids: ids || []}); } catch(e) { rej(e); }
            }); },
            listSheets: function(){ return new Promise(function(res, rej){
              window.__flymeDocSheets = res; window.__flymeDocSheetsReject = rej;
              try { post('listSheets'); } catch(e) { rej(e); }
            }); },
            login: function(){ return new Promise(function(res, rej){
              window.__flymeAuthResolve = res; window.__flymeAuthReject = rej;
              try { post('login'); } catch(e) { rej(e); }
            }); },
            logout: function(){ return new Promise(function(res){
              window.__flymeAuthResolve = res;
              try { post('logout'); } catch(e) { res(true); }
            }); },
          };
        })();
        """
        cfg.userContentController.addUserScript(WKUserScript(source: shim,
                                                            injectionTime: .atDocumentStart,
                                                            forMainFrameOnly: true))


        web = WKWebView(frame: view.bounds, configuration: cfg)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.backgroundColor = .white
        web.isOpaque = true
        view.addSubview(web)

        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "assets") else {
            return
        }
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        web.navigationDelegate = self
    }

    deinit {
        web?.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    // MARK: 页面 → 原生
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "FlymeDoc",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }

        switch action {
        case "fetchUrls":
            let ids = (body["ids"] as? [String]) ?? []
            startFetch(ids: ids)
        case "login":
            startLogin()
        case "logout":
            Task {
                await DocSync.clearCookies()
                let left = await DocSync.readCookieHeader()
                let ok = !left.contains("DOC_SID=")
                self.js("window.__flymeAuthResolve && window.__flymeAuthResolve(\(ok))")
            }
        case "listSheets":
            startListSheets()
        default:
            break
        }
    }

    private func js(_ code: String) {
        DispatchQueue.main.async { self.web?.evaluateJavaScript(code, completionHandler: nil) }
    }

    private func progress(_ text: String) {
        let safe = text.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "'", with: "\\'")
        js("window.__flymeSetProgress && window.__flymeSetProgress('\(safe)')")
    }

    private func finish(_ urls: [String]) {
        let parts = urls.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        js("window.__flymeDocResolve && window.__flymeDocResolve([\(parts.joined(separator: ","))])")
    }

    private func fail(_ message: String) {
        let safe = message.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "'", with: "\\'")
        js("window.__flymeDocReject && window.__flymeDocReject(new Error('\(safe)'))")
    }

    private func finishSheets(_ sheets: [(id: String, name: String)]) {
        let parts = sheets.map { sh -> String in
            let n = sh.name.replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"id\":\"" + sh.id + "\",\"name\":\"" + n + "\"}"
        }
        js("window.__flymeDocSheets && window.__flymeDocSheets([\(parts.joined(separator: ","))])")
    }

    private func failSheets(_ message: String) {
        let safe = message.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "'", with: "\\'")
        js("window.__flymeDocSheetsReject && window.__flymeDocSheetsReject(new Error('\(safe)'))")
    }

    private func startLogin() {
        guard !self.running else { self.failAuth("正在抓取中，请稍候"); return }
        self.running = true
        Task {
            var cookie = await DocSync.readCookieHeader()
            var xsrf: String? = nil
            if cookie.contains("DOC_SID=") { xsrf = await DocSync.tryXsrf(cookie: cookie) }
            if xsrf == nil {
                self.progress("未登录或登录已失效，正在打开登录窗口…")
                await self.presentLogin()
                guard let c1 = await self.waitForLoginCookieOrCancel() else {
                    self.failAuth("已取消登录"); self.running = false; return
                }
                cookie = c1
                if cookie.isEmpty { self.failAuth("等待登录超时"); self.running = false; return }
                for i in 0..<10 {
                    self.progress("登录成功，正在读取页面参数…（\(i + 1)/10）")
                    xsrf = await DocSync.tryXsrf(cookie: cookie)
                    if xsrf != nil { break }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    cookie = await DocSync.readCookieHeader()
                }
            }
            self.running = false
            if xsrf == nil { self.failAuth("登录后仍取不到 xsrf，请确认已进入文档页面") }
            else { self.js("window.__flymeAuthResolve && window.__flymeAuthResolve(true)") }
        }
    }

    private func failAuth(_ message: String) {
        let safe = message.replacingOccurrences(of: "\\", with: "\\\\")
                          .replacingOccurrences(of: "'", with: "\\'")
        js("window.__flymeAuthReject && window.__flymeAuthReject(new Error('\(safe)'))")
    }

    private func startListSheets() {
        if self.running { self.failSheets("正在抓取中，请稍候"); return }
        self.running = true
        Task {
            do {
                var cookie = await DocSync.readCookieHeader()
                var xsrf: String? = nil
                if cookie.contains("DOC_SID=") { xsrf = await DocSync.tryXsrf(cookie: cookie) }
                if xsrf == nil {
                    self.progress("未登录或登录已失效，正在打开登录窗口…")
                    await self.presentLogin()
                    guard let c0 = await self.waitForLoginCookieOrCancel() else {
                        throw DocError.message("已取消登录")
                    }
                    cookie = c0
                    guard !cookie.isEmpty else { throw DocError.message("等待登录超时") }
                    for i in 0..<10 {
                        self.progress("登录成功，正在读取页面参数…（\(i + 1)/10）")
                        xsrf = await DocSync.tryXsrf(cookie: cookie)
                        if xsrf != nil { break }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        cookie = await DocSync.readCookieHeader()
                    }
                    if xsrf == nil { throw DocError.message("登录后仍取不到 xsrf，请确认已进入文档页面") }
                }
                let sheets = try await DocSync.listSheets(cookie: cookie, xsrf: xsrf!)
                self.finishSheets(sheets)
            } catch {
                self.failSheets(error.localizedDescription)
            }
            self.running = false
        }
    }

    // MARK: 抓取主流程
    private func startFetch(ids: [String] = []) {
        guard !self.running else { return }
        self.running = true

        Task {
            do {
                var cookie = await DocSync.readCookieHeader()
                var xsrf: String? = nil

                if cookie.contains("DOC_SID=") {
                    self.progress("验证登录态…")
                    xsrf = await DocSync.tryXsrf(cookie: cookie)
                }

                if xsrf == nil {
                    self.progress("未登录或登录已失效，正在打开登录窗口…")
                    await self.presentLogin()
                    guard let c0 = await self.waitForLoginCookieOrCancel() else {
                        throw DocError.message("已取消登录")
                    }
                    cookie = c0
                    guard !cookie.isEmpty else { throw DocError.message("等待登录超时") }

                    for i in 0..<10 {
                        self.progress("登录成功，正在读取页面参数…（\(i + 1)/10）")
                        xsrf = await DocSync.tryXsrf(cookie: cookie)
                        if xsrf != nil { break }
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        cookie = await DocSync.readCookieHeader()
                    }
                    if xsrf == nil { throw DocError.message("登录后仍取不到 xsrf，请确认已进入文档页面") }
                }

                self.progress("开始抓取…")
                let urls = try await DocSync.fetchAll(cookie: cookie, xsrf: xsrf!, ids: ids.isEmpty ? nil : ids) { text in
                    self.progress(text)
                }
                self.progress("完成")
                self.finish(urls)
            } catch {
                self.fail((error as? DocError)?.text ?? error.localizedDescription)
            }
            self.running = false
        }
    }

    // MARK: 登录页
    /// 等登录 Cookie；用户点「关闭」返回 nil（取消）
    private func waitForLoginCookieOrCancel() async -> String? {
        for _ in 0..<180 {
            // 先看 cookie：登录成功时 VC 会被自动关闭，不能先判 nil 否则误判成“取消”
            let c = await DocSync.readCookieHeader()
            if c.contains("DOC_SID=") { return c }
            if self.loginVC == nil { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return ""
    }

    private func presentLogin() async {
        await MainActor.run {
            if self.loginVC != nil { return }
            let vc = LoginViewController(docURL: RootViewController.docURL)
            vc.modalPresentationStyle = .fullScreen
            vc.onClose = { [weak self] in self?.loginVC = nil }
            self.loginVC = vc
            self.present(vc, animated: true)
        }
    }
}

extension RootViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = (url.scheme ?? "").lowercased()
        if ["http", "https", "file", "about", "data"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        }
    }
}

// =====================================================================
// MARK: - 登录窗口
// =====================================================================
final class LoginViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"


    private let docURL: URL
    private var web: WKWebView!
    var onClose: (() -> Void)?

    init(docURL: URL) {
        self.docURL = docURL
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let bar = UIView()
        bar.backgroundColor = UIColor(red: 0.92, green: 0.95, blue: 0.98, alpha: 1)
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)

        let tip = UILabel()
        tip.text = "登录腾讯文档（登录后自动关闭）"
        tip.font = .systemFont(ofSize: 13)
        tip.textColor = UIColor(red: 0.15, green: 0.31, blue: 0.43, alpha: 1)
        tip.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(tip)

        let close = UIButton(type: .system)
        close.setTitle("关闭", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 14)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(dismissSelf), for: .touchUpInside)
        bar.addSubview(close)

        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        // 伪装成电脑端：让腾讯文档返回 PC 登录页（密码 / 二维码），不走手机 QQ 快捷登录
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = LoginViewController.desktopUA
        web.translatesAutoresizingMaskIntoConstraints = false
        web.navigationDelegate = self
        web.uiDelegate = self
        view.addSubview(web)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: safe.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),

            tip.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            tip.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            close.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            web.topAnchor.constraint(equalTo: bar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        web.load(URLRequest(url: docURL))
        pollLogin()
    }

    @objc private func dismissSelf() {
        onClose?()
        dismiss(animated: true)
    }

    private func pollLogin() {
        Task {
            for _ in 0..<180 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let cookie = await DocSync.readCookieHeader()
                if cookie.contains("DOC_SID=") {
                    await MainActor.run { self.dismissSelf() }
                    return
                }
            }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = (url.scheme ?? "").lowercased()
        if ["http", "https", "file", "about", "data"].contains(scheme) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        // 关键：不能在 decidePolicy 回调里同步 open（QQ 的 mqqapi:// 经常返回失败），
        // 放到下一个 runloop，并准备 scheme 回退。
        DispatchQueue.main.async { [weak self] in
            self?.openExternal(url)
        }
    }

    private func openExternal(_ url: URL) {
        tryOpen(candidates(for: url), index: 0, original: url)
    }

    /// QQ / 微信的 scheme 有多种写法：保留原路径，逐个换成其它已注册的 scheme 再试
    private func candidates(for url: URL) -> [URL] {
        var list: [URL] = [url]
        let scheme = (url.scheme ?? "").lowercased()

        func addSwapped(_ target: String) {
            guard target != scheme,
                  var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
            comps.scheme = target
            if let u = comps.url, !list.contains(u) { list.append(u) }
        }
        func addBare(_ target: String) {
            guard target != scheme, let u = URL(string: target + "://"), !list.contains(u) else { return }
            list.append(u)
        }

        if scheme.hasPrefix("mqq") || scheme.hasPrefix("wtlogin") {
            // QQ 网页登录历史上用过这几套 scheme，路径不变、只换 scheme 命中率最高
            for t in ["mqqapi", "mqq", "wtloginmqq", "wtloginmqq2", "mqqopensdkapiV2"] {
                addSwapped(t)
            }
            addBare("mqqapi")
            addBare("mqq")
        } else if scheme.hasPrefix("weixin") {
            addSwapped("weixin")
            addBare("weixin")
        }

        // 能打开（应用已注册该 scheme）的排前面
        let openable = list.filter { UIApplication.shared.canOpenURL($0) }
        let rest = list.filter { !UIApplication.shared.canOpenURL($0) }
        return openable + rest
    }

    private func tryOpen(_ urls: [URL], index: Int, original: URL) {
        guard index < urls.count else { showOpenFailed(original); return }
        UIApplication.shared.open(urls[index], options: [:]) { [weak self] ok in
            if ok { return }
            self?.tryOpen(urls, index: index + 1, original: original)
        }
    }

    private func showOpenFailed(_ url: URL) {
        let scheme = url.scheme ?? "?"
        let a = UIAlertController(
            title: "无法打开",
            message: "系统没能打开 \(scheme):// 链接。请确认手机已安装 QQ 且能正常打开，或在登录页改用「手机号登录 / 验证码登录」。",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "知道了", style: .default))
        present(a, animated: true)
    }
}

// =====================================================================
// MARK: - 抓取实现
// =====================================================================
enum DocError: Error {
    case message(String)
    var text: String {
        switch self { case .message(let m): return m }
    }
}

enum DocSync {

    static let docURL = URL(string: "https://docs.qq.com/sheet/DWkdWamR2bExXUWtC?tab=000002")!
    private static let docId = "DWkdWamR2bExXUWtC"
    private static let firstTab = "000002"     // 文档默认打开的工作表
    private static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

    /// 一个工作表的某一块数据
    struct TabData {
        let maxRow: Int
        let blocks: [String]
        let workbook: String
    }

    static let urlAlias: [String: String] = [
        "/Firmware/Flyme/meizu2_Pro/12.25.5.16/cn_daily/20250512191421-20250516022243/03fdf276/update.zip":
            "https://download.meizu.com/Firmware/Flyme/meizu20_Pro/12.25.5.16/cn_daily/20250512191421-20250516022243/03fdf276/update.zip",
        "/Firmware/Flyme/PRO7_Plus/6.1.2.3//20180111121511/736521af/update.zip":
            "https://download.meizu.com/Firmware/Flyme/PRO7_Plus/6.1.2.3/20180111121511/736521af/update.zip"
    ]

    static func aliasUrl(_ u: String) -> String {
        var path = u.replacingOccurrences(of: "^https?://[^/]+", with: "", options: .regularExpression)
        if let r = path.range(of: ".zip") { path = String(path[..<r.upperBound]) }
        if let hit = urlAlias[path] { return hit }
        let collapsed = path.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)
        return urlAlias[collapsed] ?? u
    }

    static func normPath(_ u: String) -> String {
        var x = u.replacingOccurrences(of: "^https?://[^/]+", with: "", options: .regularExpression)
        if let r = x.range(of: ".zip") { x = String(x[..<r.upperBound]) }
        return x.replacingOccurrences(of: "/{2,}", with: "/", options: .regularExpression)
    }

    /// K1 机型|Hash → K2 机型|时间|版本 → K3 归一化路径
    static func keyOf(_ url: String) -> String {
        let u = aliasUrl(url)
        let pattern = "/Flyme/([^/]+)/([^/]+)/([^/]+)/(\\d{14}(?:-\\d{14})?)/([0-9A-Za-z]{8})/update\\.zip"
        if let re = try? NSRegularExpression(pattern: pattern),
           let m = re.firstMatch(in: u, range: NSRange(location: 0, length: (u as NSString).length)) {
            func g(_ i: Int) -> String {
                guard let r = Range(m.range(at: i), in: u) else { return "" }
                return String(u[r])
            }
            var a = g(1), b = g(2)
            let isVer = { (t: String) in t.range(of: "^\\d+(\\.\\d+)+$", options: .regularExpression) != nil }
            if isVer(a) && !isVer(b) { let t = a; a = b; b = t }
            let h = g(5).lowercased()
            if !h.isEmpty { return "K1:" + a.lowercased() + "|" + h }
            return "K2:" + a.lowercased() + "|" + g(4) + "|" + b
        }
        return "K3:" + normPath(u)
    }

    static func readCookieHeader() async -> String {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let qq = cookies.filter { $0.domain.contains("qq.com") }
                let header = qq.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                cont.resume(returning: header)
            }
        }
    }

    static func clearCookies() async {
        let store = WKWebsiteDataStore.default()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                             modifiedSince: .distantPast) { cont.resume() }
        }
        // 清掉 WKWebView 的 cookie 还不够：URLSession 还有一份 HTTPCookieStorage
        if let shared = HTTPCookieStorage.shared.cookies {
            for c in shared { HTTPCookieStorage.shared.deleteCookie(c) }
        }
        URLCache.shared.removeAllCachedResponses()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.getAllCookies { cookies in
                for c in cookies { store.httpCookieStore.delete(c) }
                cont.resume()
            }
        }
    }

    static func tryXsrf(cookie: String) async -> String? {
        guard let html = try? await get(DocSync.docURL, cookie: cookie) else { return nil }
        guard let re = try? NSRegularExpression(pattern: "xsrf=([0-9a-f]{6,})", options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// 从 workbook（protobuf）解析全部工作表：1a 08 0a 06 <6字节id> … 2a <len> 0a <名字长> <名字>
    static func parseSheets(_ workbook: String) -> [(id: String, name: String)] {
        var s = workbook.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let raw = Data(base64Encoded: s), raw.count > 16 else { return [] }
        guard let data = inflate(raw) else { return [] }

        let b = [UInt8](data)
        var out: [(String, String)] = []
        var seen = Set<String>()
        var i = 0
        while i + 10 < b.count {
            if b[i] == 0x1A && b[i + 1] == 0x08 && b[i + 2] == 0x0A && b[i + 3] == 0x06 {
                let idBytes = b[(i + 4)..<(i + 10)]
                let id = String(bytes: idBytes, encoding: .isoLatin1) ?? ""
                let valid = id.count == 6 && id.allSatisfy { $0.isLetter || $0.isNumber }
                if valid && !seen.contains(id) {
                    var name = ""
                    var k = i + 10
                    while k < min(b.count - 3, i + 60) {
                        if b[k] == 0x2A && b[k + 2] == 0x0A {
                            let nl = Int(b[k + 3])
                            if nl > 0 && k + 4 + nl <= b.count {
                                name = String(bytes: b[(k + 4)..<(k + 4 + nl)], encoding: .utf8) ?? ""
                            }
                            break
                        }
                        k += 1
                    }
                    if !name.isEmpty {
                        seen.insert(id)
                        out.append((id, name))
                    }
                }
            }
            i += 1
        }
        return out
    }

    /// 取某个工作表某一块的数据
    static func fetchTab(cookie: String, xsrf: String, tab: String, start: Int) async throws -> TabData {
        var comps = URLComponents(string: "https://docs.qq.com/dop-api/opendoc")!
        comps.queryItems = [
            URLQueryItem(name: "id", value: docId),
            URLQueryItem(name: "tab", value: tab),
            URLQueryItem(name: "startrow", value: "\(start)"),
            URLQueryItem(name: "endrow", value: "\(start + 255)"),
            URLQueryItem(name: "block_start_row", value: "\(start)"),
            URLQueryItem(name: "block_end_row", value: "\(start + 255)"),
            URLQueryItem(name: "block_start_col", value: "0"),
            URLQueryItem(name: "block_end_col", value: "31"),
            URLQueryItem(name: "needSheetState", value: "1"),
            URLQueryItem(name: "sliceStates", value: "1"),
            URLQueryItem(name: "noEscape", value: "1"),
            URLQueryItem(name: "enableSmartsheetSplit", value: "1"),
            URLQueryItem(name: "normal", value: "1"),
            URLQueryItem(name: "outformat", value: "1"),
            URLQueryItem(name: "wb", value: "1"),
            URLQueryItem(name: "nowb", value: "0"),
            URLQueryItem(name: "callback", value: "clientVarsCallback"),
            URLQueryItem(name: "xsrf", value: xsrf)
        ]

        let body = try await get(comps.url!, cookie: cookie)
        guard let l = body.firstIndex(of: "("), let r = body.lastIndex(of: ")"), l < r else {
            throw DocError.message("响应格式异常")
        }
        let json = String(body[body.index(after: l)..<r])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cv = obj["clientVars"] as? [String: Any],
              let ccv = cv["collab_client_vars"] as? [String: Any],
              let iat = ccv["initialAttributedText"] as? [String: Any],
              let arr = iat["text"] as? [[String: Any]],
              let t0 = arr.first else {
            throw DocError.message("响应结构变了：找不到 initialAttributedText")
        }

        let maxRow = (t0["max_row"] as? Int) ?? 0
        var blocks: [String] = []
        if let list = t0["block_datas"] as? [[String: Any]] {
            for b in list {
                if let b64 = b["related_sheet"] as? String, !b64.isEmpty { blocks.append(b64) }
            }
        }
        let workbook = (t0["workbook"] as? String) ?? ""
        return TabData(maxRow: maxRow, blocks: blocks, workbook: workbook)
    }

    /// 只读工作簿列表
    static func listSheets(cookie: String, xsrf: String) async throws -> [(id: String, name: String)] {
        let first = try await fetchTab(cookie: cookie, xsrf: xsrf, tab: firstTab, start: 0)
        var sheets = parseSheets(first.workbook)
        if sheets.isEmpty { sheets = [(firstTab, "默认工作表")] }
        return sheets
    }

    /// 抓取全部工作表
    static func fetchAll(cookie: String, xsrf: String, ids: [String]? = nil,
                         progress: @escaping (String) -> Void) async throws -> [String] {
        var seen = [String: String]()

        progress("读取工作表列表…")
        let first = try await fetchTab(cookie: cookie, xsrf: xsrf, tab: firstTab, start: 0)

        var sheets = parseSheets(first.workbook)
        if sheets.isEmpty { sheets = [(firstTab, "默认工作表")] }
        if let ids = ids, !ids.isEmpty {
            let want = Set(ids.map { String($0) })
            sheets = sheets.filter { want.contains($0.id) }
        }
        if sheets.isEmpty { throw DocError.message("没有勾选任何工作表") }

        progress("共 \(sheets.count) 个工作表：\(sheets.map { $0.name }.joined(separator: " / "))，开始抓取…")

        for (idx, sh) in sheets.enumerated() {
            var start = 0, round = 0, maxRow = 0

            while round < 12 {
                let t0: TabData
                if idx == 0 && round == 0 {
                    t0 = first
                } else {
                    progress("工作表 \(idx + 1)/\(sheets.count)「\(sh.name)」" +
                             (round > 0 ? "第 \(round + 1) 块" : "") + "，已 \(seen.count) 条…")
                    t0 = try await fetchTab(cookie: cookie, xsrf: xsrf, tab: sh.id, start: start)
                }

                maxRow = t0.maxRow > 0 ? t0.maxRow : maxRow
                for b64 in t0.blocks {
                    if let text = inflateText(b64) { extract(text, into: &seen) }
                }

                round += 1
                start += 256
                if t0.blocks.isEmpty || (maxRow > 0 && start >= maxRow) { break }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }

            progress("已完成 \(idx + 1)/\(sheets.count)「\(sh.name)」，累计 \(seen.count) 条")
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        return Array(seen.values)
    }

    private static func extract(_ text: String, into map: inout [String: String]) {
        guard let re = try? NSRegularExpression(pattern: "https?://[^\"\\s\\\\]+?update\\.zip") else { return }
        let ns = text as NSString
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m else { return }
            let u = aliasUrl(ns.substring(with: m.range))
            let k = keyOf(u)
            if map[k] == nil { map[k] = u }
        }
    }

    // zlib 包装：去掉 2 字节头，用 raw deflate 解
    static func inflate(_ raw: Data) -> Data? {
        guard raw.count > 6 else { return nil }
        let body = raw.subdata(in: (raw.startIndex + 2)..<raw.endIndex)
        for size in [1 << 20, 4 << 20, 16 << 20, 64 << 20] {
            var out = Data(count: size)
            let n = out.withUnsafeMutableBytes { dst -> Int in
                guard let dstPtr = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return body.withUnsafeBytes { src -> Int in
                    guard let srcPtr = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dstPtr, size, srcPtr, body.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 { return out.prefix(n) }
        }
        return nil
    }

    /// base64 + zlib -> 文本
    static func inflateText(_ b64: String) -> String? {
        var s = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let raw = Data(base64Encoded: s) else { return nil }
        guard let data = inflate(raw) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func get(_ url: URL, cookie: String) async throws -> String {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue(cookie, forHTTPHeaderField: "cookie")
        if url.host == "docs.qq.com" {
            req.setValue(docURL.absoluteString, forHTTPHeaderField: "referer")
        }

        return try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err { cont.resume(throwing: err); return }
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    cont.resume(throwing: DocError.message("HTTP \(http.statusCode)"))
                    return
                }
                cont.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            }.resume()
        }
    }
}
