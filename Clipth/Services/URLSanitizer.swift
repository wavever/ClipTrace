import Foundation

/// Strips tracking / analytics query parameters from URLs so the clipboard
/// stores the "clean" form that's safe to share. Conservative: only well-known
/// tracking names are removed — generic ones like `ref` are kept since they
/// carry meaning on GitHub, Reddit, etc.
enum URLSanitizer {
    static let trackingParams: Set<String> = [
        // Urchin / Google Analytics
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "utm_name", "utm_brand", "utm_social", "utm_social_type",
        // Google ads & DoubleClick
        "gclid", "gclsrc", "gbraid", "wbraid", "gad_source", "dclid",
        // Facebook / Instagram
        "fbclid", "igshid", "igsh",
        // Microsoft ads
        "msclkid",
        // Mailchimp
        "mc_eid", "mc_cid",
        // Marketo
        "mkt_tok",
        // LinkedIn
        "li_fat_id",
        // TikTok
        "ttclid",
        // Twitter / X
        "twclid",
        // Yandex
        "yclid", "ymclid",
        // HubSpot
        "_hsenc", "_hsmi", "_hsfp", "__hssc", "__hstc", "hsctatracking",
        // Yahoo Japan
        "_openstat",
        // Adobe Marketing
        "s_cid", "icid",
        // eBay
        "mkevt", "mkcid", "mkrid",
        // Alibaba / Taobao
        "spm", "scm",
        // Vero
        "vero_conv", "vero_id"
    ]

    /// Returns the URL string with tracking params stripped. If `urlString` is
    /// not a parseable URL or carries no query, the original string is
    /// returned unchanged.
    static func clean(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              let items = components.queryItems, !items.isEmpty else {
            return urlString
        }
        let kept = items.filter { !trackingParams.contains($0.name.lowercased()) }
        guard kept.count != items.count else { return urlString }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url?.absoluteString ?? urlString
    }
}
