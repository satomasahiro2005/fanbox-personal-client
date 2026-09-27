import Foundation
import UIKit
import UserNotifications

/// Option lists and pure display helpers used by the Settings screens (unit-tested).
enum SettingsChoices {
    /// Foreground notification polling intervals (seconds).
    static let pollingIntervals: [TimeInterval] = [30, 60, 120, 300, 900]
    /// "長時間経過した返信" threshold choices (seconds), SPEC §22.
    static let staleReplyThresholds: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60, 3 * 3600, 12 * 3600, 24 * 3600]
    /// "Creator の最近 N 件" (SPEC §31). Bounded on purpose: no unlimited history crawl (SPEC §3.7).
    static let creatorRecentCountRange: ClosedRange<Int> = 1...50

    /// Options that always contain `current` (so a Picker never has a selection without a matching tag).
    static func options(_ base: [TimeInterval], including current: TimeInterval) -> [TimeInterval] {
        base.contains(current) ? base : (base + [current]).sorted()
    }

    /// 30 → "30秒", 60 → "1分", 5400 → "1時間30分", 86400 → "24時間".
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)秒" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours)時間") }
        if minutes > 0 { parts.append("\(minutes)分") }
        if secs > 0 { parts.append("\(secs)秒") }
        return parts.joined()
    }
}

/// App version shown at the bottom of Settings.
enum AppVersionInfo {
    static func displayString(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Human-readable labels for OS-level states.
enum SystemStatusText {
    static func notificationAuthorization(_ status: UNAuthorizationStatus?) -> String {
        guard let status else { return "確認中…" }
        switch status {
        case .notDetermined: return "未確認"
        case .denied: return "拒否"
        case .authorized: return "許可"
        case .provisional: return "仮許可"
        case .ephemeral: return "一時的に許可"
        @unknown default: return "不明"
        }
    }

    static func backgroundRefresh(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available: return "利用可能"
        case .denied: return "オフ（iOSの設定）"
        case .restricted: return "制限されています"
        @unknown default: return "不明"
        }
    }

    static func yesNo(_ value: Bool) -> String { value ? "はい" : "いいえ" }
    static func presence(_ value: Bool) -> String { value ? "あり" : "なし" }
    static func onOff(_ value: Bool) -> String { value ? "ON" : "OFF" }

    static func sessionState(_ state: SessionState) -> String {
        switch state {
        case .unknown: return "未確認（unknown）"
        case .valid: return "有効（valid）"
        case .expired: return "期限切れ（expired）"
        case .loggedOut: return "ログアウト（loggedOut）"
        case .error: return "エラー（error）"
        }
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.year().month().day().hour().minute().second())
    }
}

/// Optional APNs relay helpers (SPEC §28). The relay itself is not part of v1.0; see docs/NOTIFICATION_RELAY.md.
enum RelaySettingsSupport {
    enum URLValidation: Equatable, Sendable {
        case empty
        case valid(URL)
        /// Only https is accepted: the device token and account hints must not travel in clear text.
        case notHTTPS
        case invalid
    }

    static func validate(_ raw: String) -> URLValidation {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, let url = components.url else { return .invalid }
        guard scheme == "https" else { return .notHTTPS }
        // Credentials embedded in the URL would end up in logs / backups.
        guard components.user == nil, components.password == nil else { return .invalid }
        return .valid(url)
    }

    static func validationMessage(_ validation: URLValidation) -> String? {
        switch validation {
        case .empty: return "RelayのURLが未設定です"
        case .valid: return nil
        case .notHTTPS: return "https://のURLのみ使用できます"
        case .invalid: return "URLの形式が正しくありません（ユーザー名やパスワードをURLに含めないでください）"
        }
    }

    /// Only a short prefix of the APNs device token is ever shown.
    static func tokenHint(_ token: String?) -> String {
        guard let token, !token.isEmpty else { return "未取得" }
        return "\(token.prefix(8))…（\(token.count)桁）"
    }

    enum RegistrationState: Equatable, Sendable {
        case disabled
        case urlMissing
        case waitingForToken
        case failed
        case tokenReady
    }

    static func registrationState(enabled: Bool, urlText: String, token: String?, lastError: String?) -> RegistrationState {
        guard enabled else { return .disabled }
        guard case .valid = validate(urlText) else { return .urlMissing }
        if token?.isEmpty == false { return .tokenReady }
        if lastError?.isEmpty == false { return .failed }
        return .waitingForToken
    }

    static func registrationText(_ state: RegistrationState) -> String {
        switch state {
        case .disabled: return "オフ"
        case .urlMissing: return "Relay URLを設定してください"
        case .waitingForToken: return "APNsデバイストークン待ち"
        case .failed: return "APNs登録に失敗しました"
        case .tokenReady: return "デバイストークン取得済み"
        }
    }
}
