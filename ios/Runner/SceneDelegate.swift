import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    if let url = connectionOptions.urlContexts.first?.url,
       url.scheme?.lowercased() == "bmray" {
      AppDelegate.pendingDeepLink = url.absoluteString
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts where context.url.scheme?.lowercased() == "bmray" {
      let link = context.url.absoluteString
      if link.count <= 1024 * 1024 {
        AppDelegate.pendingDeepLink = link
        AppDelegate.deepLinkChannel?.invokeMethod("deepLink", arguments: link)
      }
    }
    super.scene(scene, openURLContexts: URLContexts)
  }
}
