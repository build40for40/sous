import UIKit
import UniformTypeIdentifiers

/// "Share → Sous" on iOS. Takes the link, text or image another app shared,
/// hands it to the Sous app through the app group, and opens Sous, which sends
/// it to the extraction API (see lib/shares/).
///
/// The hand-off uses receive_sharing_intent's format, so the plugin's app side
/// picks it up unchanged: a JSON list of shared items under "ShareKey" in the
/// app group's UserDefaults, then the URL "ShareMedia-<app bundle id>:share".
/// Written here instead of subclassing the plugin's RSIShareViewController,
/// which is only available as a Swift package the extension can't link
/// without Xcode-only setup.
final class ShareViewController: UIViewController {
  private struct SharedItem: Codable {
    var path: String
    var mimeType: String?
    var thumbnail: String?
    var duration: Double?
    var message: String?
    var type: String  // "text", "url" or "image"
  }

  private var handled = false

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !handled else { return }
    handled = true
    Task { await handle() }
  }

  private var hostBundleId: String {
    let id = Bundle.main.bundleIdentifier ?? "com.build40for40.sous.ShareExtension"
    return id.components(separatedBy: ".").dropLast().joined(separator: ".")
  }

  private var appGroupId: String {
    (Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String)
      .flatMap { $0.isEmpty ? nil : $0 } ?? "group.\(hostBundleId)"
  }

  @MainActor
  private func handle() async {
    var items: [SharedItem] = []
    let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
    for provider in providers {
      if let item = await load(provider) { items.append(item) }
    }
    guard !items.isEmpty, let defaults = UserDefaults(suiteName: appGroupId),
      let data = try? JSONEncoder().encode(items)
    else {
      extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
      return
    }
    defaults.set(data, forKey: "ShareKey")
    defaults.removeObject(forKey: "ShareMessageKey")
    defaults.synchronize()
    openHostApp()
    extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
  }

  private func load(_ provider: NSItemProvider) async -> SharedItem? {
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
      let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL,
      !url.isFileURL
    {
      return SharedItem(path: url.absoluteString, mimeType: "text/plain", type: "url")
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
      let path = await saveImage(provider)
    {
      return SharedItem(path: path, mimeType: "image/jpeg", type: "image")
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
        as? String,
      !text.isEmpty
    {
      return SharedItem(path: text, mimeType: "text/plain", type: "text")
    }
    return nil
  }

  /// Copies the image into the app group, where the app can read it.
  private func saveImage(_ provider: NSItemProvider) async -> String? {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupId)
    else { return nil }
    let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
    let data: Data?
    switch item {
    case let url as URL: data = try? Data(contentsOf: url)
    case let image as UIImage: data = image.jpegData(compressionQuality: 0.9)
    case let raw as Data: data = raw
    default: data = nil
    }
    guard let data else { return nil }
    let target = container.appendingPathComponent("share-\(UUID().uuidString).img")
    do {
      try data.write(to: target)
    } catch {
      return nil
    }
    // A file:// URL, which the plugin turns back into a path.
    return target.absoluteString
  }

  /// Opens Sous through the responder chain, the way receive_sharing_intent's
  /// own extension does. Extensions must build extension-safe
  /// (APPLICATION_EXTENSION_API_ONLY = YES, which Flutter checks), where
  /// UIApplication.open isn't available to call directly, so it's called
  /// through the Objective-C runtime.
  private func openHostApp() {
    guard let url = URL(string: "ShareMedia-\(hostBundleId):share") else { return }
    var responder: UIResponder? = self
    while let current = responder {
      if current is UIApplication {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard current.responds(to: selector), let method = current.method(for: selector) else {
          return
        }
        typealias OpenURL = @convention(c) (
          AnyObject, Selector, URL, [String: Any], ((Bool) -> Void)?
        ) -> Void
        unsafeBitCast(method, to: OpenURL.self)(current, selector, url, [:], nil)
        return
      }
      responder = current.next
    }
  }
}
