import Foundation
import WebKit

/// Research Mode capture of the requests a FANBOX page makes inside the account web view (SPEC §36 "Web フローの調査").
///
/// Some endpoints were not found by the API research — most importantly the post editor's media upload
/// (docs/API.md §15.1). With Research Mode on, the web editor's own `fetch` / `XMLHttpRequest` calls are recorded so the
/// endpoint can be read from the user's OWN session on a device instead of being guessed.
///
/// Only the structure of each call is recorded: method, redacted URL, status, content type, the NAMES of form / JSON
/// fields, and type + size of file parts, plus the top-level key names of a JSON answer. Values and bodies are never
/// captured, and everything still goes through `SecretRedactor` (SPEC §38). The script is installed only while
/// Research Mode is on, and messages are accepted only from fanbox.cc / pixiv.net frames.
enum WebPageRequestCapture {
    static let handlerName = "fanboxResearchCapture"
    /// Upper bound for field / key lists taken from one message (page scripts could post anything).
    static let maxNames = 50
    static let maxNameLength = 80

    struct Captured: Equatable, Sendable {
        var via: String
        var method: String
        var url: String
        var status: Int
        var contentType: String
        var bodyKind: String
        var fields: [String]
        var files: [String]
        var jsonKeys: [String]
        var responseKeys: [String]
        var durationMs: Int?
        var error: String?
    }

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }

    /// True for frames whose origin is FANBOX / pixiv (captures from any other site are ignored).
    static func acceptsOrigin(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["fanbox.cc", "pixiv.net"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Parses a message body posted by the script. Returns nil for anything malformed.
    static func parse(_ body: Any) -> Captured? {
        guard let dict = body as? [String: Any],
              let method = dict["method"] as? String,
              let url = dict["url"] as? String, !url.isEmpty else { return nil }
        let bodyInfo = dict["body"] as? [String: Any] ?? [:]
        func names(_ value: Any?) -> [String] {
            ((value as? [Any]) ?? []).compactMap { $0 as? String }.prefix(maxNames).map { String($0.prefix(maxNameLength)) }
        }
        return Captured(
            via: (dict["via"] as? String) ?? "fetch",
            method: String(method.prefix(10)).uppercased(),
            url: String(url.prefix(2_000)),
            status: (dict["status"] as? NSNumber)?.intValue ?? 0,
            contentType: String(((dict["ct"] as? String) ?? "").prefix(120)),
            bodyKind: String(((bodyInfo["kind"] as? String) ?? "none").prefix(20)),
            fields: names(bodyInfo["fields"]),
            files: names(bodyInfo["files"]),
            jsonKeys: names(bodyInfo["jsonKeys"]),
            responseKeys: names(dict["responseKeys"]),
            durationMs: (dict["ms"] as? NSNumber)?.intValue,
            error: (dict["error"] as? String).map { String($0.prefix(200)) }
        )
    }

    /// Redacted Research Mode entry for one captured call.
    static func entry(for captured: Captured, accountID: String, pageURL: URL?) -> ResearchEntry {
        var request = "# transport: web-page (captured from the account web view, \(captured.via))\n"
        if let pageURL { request += "# page: \(SecretRedactor.redactURL(pageURL))\n" }
        request += "# body: \(captured.bodyKind)"
        if !captured.fields.isEmpty { request += "\n# form fields: \(captured.fields.joined(separator: ", "))" }
        if !captured.files.isEmpty { request += "\n# file parts (name:type:bytes): \(captured.files.joined(separator: ", "))" }
        if !captured.jsonKeys.isEmpty { request += "\n# JSON keys: \(captured.jsonKeys.joined(separator: ", "))" }
        var response = "content-type: \(captured.contentType)"
        if !captured.responseKeys.isEmpty { response += "\nresponse body keys: \(captured.responseKeys.joined(separator: ", "))" }
        return ResearchEntry(kind: .request, accountID: accountID, method: captured.method,
                             endpoint: SecretRedactor.redactURLString(absolute(captured.url, relativeTo: pageURL)),
                             statusCode: captured.status == 0 ? nil : captured.status, durationMs: captured.durationMs,
                             requestHeaders: SecretRedactor.redact(request),
                             responseHeaders: SecretRedactor.redact(response),
                             errorDescription: captured.error.map(SecretRedactor.redact))
    }

    static func absolute(_ url: String, relativeTo page: URL?) -> String {
        if let page, let resolved = URL(string: url, relativeTo: page) { return resolved.absoluteString }
        return url
    }

    /// Wraps `fetch` and `XMLHttpRequest` in the page world. Posts structure only (no values, no bodies).
    static let source = #"""
    (() => {
      if (window.__fanboxResearchCapture) return;
      window.__fanboxResearchCapture = true;
      const post = (d) => { try { window.webkit.messageHandlers.fanboxResearchCapture.postMessage(d); } catch (e) {} };
      const describe = (body) => {
        const r = { kind: 'none', fields: [], files: [], jsonKeys: [] };
        if (body === undefined || body === null) return r;
        try {
          if (typeof FormData !== 'undefined' && body instanceof FormData) {
            r.kind = 'formdata';
            for (const [k, v] of body.entries()) {
              if (typeof Blob !== 'undefined' && v instanceof Blob) r.files.push(k + ':' + (v.type || '') + ':' + v.size);
              else r.fields.push(k);
            }
          } else if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
            r.kind = 'urlencoded';
            for (const k of body.keys()) r.fields.push(k);
          } else if (typeof Blob !== 'undefined' && body instanceof Blob) {
            r.kind = 'blob';
            r.files.push('blob:' + (body.type || '') + ':' + body.size);
          } else if (typeof body === 'string') {
            r.kind = 'text';
            try {
              const o = JSON.parse(body);
              if (o && typeof o === 'object' && !Array.isArray(o)) { r.kind = 'json'; r.jsonKeys = Object.keys(o); }
            } catch (e) {}
          } else {
            r.kind = typeof body;
          }
        } catch (e) {}
        return r;
      };
      const keysOf = (j) => {
        if (!j || typeof j !== 'object') return [];
        const b = (j.body && typeof j.body === 'object' && !Array.isArray(j.body)) ? j.body : j;
        return Array.isArray(b) ? ['[array]'] : Object.keys(b);
      };
      const origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function (input, init) {
          const url = (typeof input === 'string') ? input : ((input && input.url) || String(input));
          const method = (init && init.method) || (input && input.method) || 'GET';
          const d = describe(init && init.body);
          const t0 = Date.now();
          return origFetch.apply(this, arguments).then((res) => {
            const ct = (res.headers && res.headers.get('content-type')) || '';
            const done = (keys) => post({ via: 'fetch', method, url, status: res.status, ct, body: d, responseKeys: keys, ms: Date.now() - t0 });
            if (ct.indexOf('json') >= 0) { res.clone().json().then((j) => done(keysOf(j))).catch(() => done([])); } else { done([]); }
            return res;
          }, (err) => {
            post({ via: 'fetch', method, url, status: 0, ct: '', body: d, responseKeys: [], ms: Date.now() - t0, error: String(err) });
            throw err;
          });
        };
      }
      const XO = XMLHttpRequest.prototype.open;
      const XS = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__fanboxCapture = { method: String(m), url: String(u) }; return XO.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function (body) {
        const c = this.__fanboxCapture || { method: 'GET', url: '' };
        const d = describe(body);
        const t0 = Date.now();
        const xhr = this;
        this.addEventListener('loadend', () => {
          let keys = [];
          let ct = '';
          try {
            ct = xhr.getResponseHeader('content-type') || '';
            if (ct.indexOf('json') >= 0 && (xhr.responseType === '' || xhr.responseType === 'text')) keys = keysOf(JSON.parse(xhr.responseText));
            else if (xhr.responseType === 'json') keys = keysOf(xhr.response);
          } catch (e) {}
          post({ via: 'xhr', method: c.method, url: c.url, status: xhr.status, ct, body: d, responseKeys: keys, ms: Date.now() - t0 });
        });
        return XS.apply(this, arguments);
      };
    })();
    """#
}

/// Receives captured calls from the page world and records them (Research Mode only).
@MainActor
final class WebPageRequestCaptureHandler: NSObject, WKScriptMessageHandler {
    let accountID: String
    let research: ResearchRecorder

    init(accountID: String, research: ResearchRecorder) {
        self.accountID = accountID
        self.research = research
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard research.capturesBodies,
              WebPageRequestCapture.acceptsOrigin(host: message.frameInfo.securityOrigin.host),
              let captured = WebPageRequestCapture.parse(message.body) else { return }
        research.record(WebPageRequestCapture.entry(for: captured, accountID: accountID, pageURL: message.frameInfo.request.url))
    }
}
