import Foundation

struct CustomASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.custom
    static var displayName: String { L("自定义", "Custom") }

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "endpointURL", label: L("端点 URL", "Endpoint URL"), placeholder: L("wss://... 或 https://...", "wss://... or https://..."), isSecure: false, isOptional: false, defaultValue: ""),
        CredentialField(key: "apiKey", label: L("API Key / Token", "API Key / Token"), placeholder: L("认证密钥", "Auth key"), isSecure: true, isOptional: true, defaultValue: ""),
        CredentialField(key: "secretKey", label: L("Secret Key", "Secret Key"), placeholder: L("可选", "Optional"), isSecure: true, isOptional: true, defaultValue: ""),
        CredentialField(key: "appId", label: L("App ID", "App ID"), placeholder: L("可选", "Optional"), isSecure: false, isOptional: true, defaultValue: ""),
        CredentialField(key: "region", label: L("区域", "Region"), placeholder: L("可选", "Optional"), isSecure: false, isOptional: true, defaultValue: ""),
        CredentialField(key: "skipAppRefine", label: L("跳过 App 润色（网关已润色）", "Skip app refinement (gateway already refines)"), placeholder: "", isSecure: false, isOptional: true, defaultValue: "true", isToggle: true),
    ]}

    let endpointURL: String
    let apiKey: String?
    let secretKey: String?
    let appId: String?
    let region: String?
    /// When true, the app skips its own LLM post-processing because the gateway
    /// (typeless2api) already refined the text. Default on. See RecognitionSession.
    let skipAppRefine: Bool

    init?(credentials: [String: String]) {
        guard let url = credentials["endpointURL"], !url.isEmpty else { return nil }
        self.endpointURL = url
        self.apiKey = credentials["apiKey"]
        self.secretKey = credentials["secretKey"]
        self.appId = credentials["appId"]
        self.region = credentials["region"]
        self.skipAppRefine = credentials["skipAppRefine"].map { $0 == "true" } ?? true
    }

    func toCredentials() -> [String: String] {
        var result = ["endpointURL": endpointURL]
        if let v = apiKey, !v.isEmpty { result["apiKey"] = v }
        if let v = secretKey, !v.isEmpty { result["secretKey"] = v }
        if let v = appId, !v.isEmpty { result["appId"] = v }
        if let v = region, !v.isEmpty { result["region"] = v }
        result["skipAppRefine"] = skipAppRefine ? "true" : "false"
        return result
    }

    var isValid: Bool { !endpointURL.isEmpty }
}
