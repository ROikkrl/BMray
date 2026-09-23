#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vpn_plugin.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'vpn_plugin'
  s.version          = '0.1.0'
  s.summary          = 'Flutter VPN engine embedding the sing-box core (GPL-3.0).'
  s.description      = <<-DESC
App-side NetworkExtension bridge for the sing-box VPN engine. The tunnel itself
runs in the host app's PacketTunnel extension target (added via the bundled
tool/add_extension_target.rb). sing-box is GPL-3.0.
                       DESC
  s.homepage         = 'https://github.com/WillJard99/flutter_vpn_plugin'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'vpn_plugin' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  # Only the app-side bridge is compiled by the pod. The extension Swift under
  # ios/extension/ is added to the host's separate extension target by the setup script.
  s.source_files = 'vpn_plugin/Sources/vpn_plugin/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'vpn_plugin_privacy' => ['vpn_plugin/Sources/vpn_plugin/PrivacyInfo.xcprivacy']}
end
