#!/usr/bin/env ruby
# frozen_string_literal: true
#
# One-time iOS setup for flutter_singbox_vpn.
#
# Run from your app's `ios/` directory (after `flutter pub get` + `pod install`):
#
#   ruby .symlinks/plugins/flutter_singbox_vpn/tool/add_extension_target.rb
#
# It creates the `SingboxTunnel` packet-tunnel extension target in your
# Runner.xcodeproj, copies the plugin's extension Swift in, downloads + links the
# sing-box Libbox.xcframework, wires App Group + NetworkExtension entitlements on
# both targets, sets the Info.plist keys the plugin reads, and embeds the
# extension into the app. Idempotent.
#
# Config via env (all optional — sane defaults are derived from your Runner target):
#   APP_GROUP        default: group.<your app bundle id>
#   TUNNEL_BUNDLE_ID default: <your app bundle id>.SingboxTunnel
#   DEV_TEAM         default: your Runner DEVELOPMENT_TEAM
#   LIBBOX_URL       URL to Libbox.xcframework.zip (defaults to a release placeholder)
require 'xcodeproj'
require 'fileutils'
require 'digest'

PROJECT = File.expand_path('Runner.xcodeproj')
abort "Run me from your app's ios/ directory (Runner.xcodeproj not found)." unless File.exist?(PROJECT)

project = Xcodeproj::Project.open(PROJECT)
runner = project.targets.find { |t| t.name == 'Runner' } or abort 'Runner target not found'
runner_cfg = runner.build_configurations.first.build_settings
APP_ID = runner_cfg['PRODUCT_BUNDLE_IDENTIFIER'] || 'com.example.app'
TEAM = ENV['DEV_TEAM'] || runner_cfg['DEVELOPMENT_TEAM'] || ''
APP_GROUP = ENV['APP_GROUP'] || "group.#{APP_ID}"
EXT_NAME = 'SingboxTunnel'
EXT_ID = ENV['TUNNEL_BUNDLE_ID'] || "#{APP_ID}.#{EXT_NAME}"
DEPLOY = '15.0'
LIBBOX_URL = ENV['LIBBOX_URL'] ||
             'https://github.com/WillJard99/flutter_vpn_plugin/releases/download/v1.13.13/Libbox.xcframework.zip'
LIBBOX_SHA256 = ENV['LIBBOX_SHA256'] ||
                'afd3bf2e53da9b3f329105415056786e1d02aab3b7aca760fb5ccff84ab561ca'

PLUGIN_EXT_DIR = ENV['SINGBOX_EXT_DIR'] ||
                 Dir.glob('.symlinks/plugins/vpn_plugin/ios/extension').first ||
                 Dir.glob('**/vpn_plugin/ios/extension').first
abort 'Plugin extension sources not found (run flutter pub get first).' unless PLUGIN_EXT_DIR && Dir.exist?(PLUGIN_EXT_DIR)

puts "app=#{APP_ID} team=#{TEAM} group=#{APP_GROUP} ext=#{EXT_ID}"

# ---- copy extension Swift into the host project ----
ext_dir = EXT_NAME
FileUtils.mkdir_p(ext_dir)
%w[PacketTunnelProvider.swift PlatformBridge.swift Runtime.swift].each do |f|
  FileUtils.cp(File.join(PLUGIN_EXT_DIR, f), File.join(ext_dir, f))
end

# ---- Info.plist + entitlements for the extension ----
File.write(File.join(ext_dir, 'Info.plist'), <<~PLIST)
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
    <key>CFBundleDevelopmentRegion</key><string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleDisplayName</key><string>#{EXT_NAME}</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>SingboxVpnAppGroup</key><string>#{APP_GROUP}</string>
    <key>NSExtension</key><dict>
      <key>NSExtensionPointIdentifier</key><string>com.apple.networkextension.packet-tunnel</string>
      <key>NSExtensionPrincipalClass</key><string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
    </dict>
  </dict></plist>
PLIST

ent = <<~ENT
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0"><dict>
    <key>com.apple.developer.networking.networkextension</key><array><string>packet-tunnel-provider</string></array>
    <key>com.apple.security.application-groups</key><array><string>#{APP_GROUP}</string></array>
  </dict></plist>
ENT
File.write(File.join(ext_dir, "#{EXT_NAME}.entitlements"), ent)
File.write('Runner/Runner.entitlements', ent)

# ---- download Libbox.xcframework ----
fw = 'Frameworks/Libbox.xcframework'
unless Dir.exist?(fw)
  FileUtils.mkdir_p('Frameworks')
  puts "Downloading Libbox.xcframework from #{LIBBOX_URL} ..."
  zip = 'Frameworks/Libbox.xcframework.zip'
  system('curl', '-fSL', LIBBOX_URL, '-o', zip) or abort 'download failed (set LIBBOX_URL or build it with scripts/build_libbox_ios.sh)'
  abort 'Libbox.xcframework checksum mismatch' unless Digest::SHA256.file(zip).hexdigest == LIBBOX_SHA256
  system('unzip', '-q', '-o', zip, '-d', 'Frameworks') or abort 'unzip failed'
  File.delete(zip)
end

# ---- Runner: entitlements + Info.plist keys + team ----
runner.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
  c.build_settings['DEVELOPMENT_TEAM'] = TEAM unless TEAM.empty?
end
info = 'Runner/Info.plist'
if File.exist?(info)
  plist = Xcodeproj::Plist.read_from_path(info)
  plist['SingboxVpnAppGroup'] = APP_GROUP
  plist['SingboxVpnTunnelBundleId'] = EXT_ID
  Xcodeproj::Plist.write_to_path(plist, info)
end

EXT_LDFLAGS = ['$(inherited)', '-lresolv', '-framework', 'UIKit', '-framework', 'Security',
               '-framework', 'SystemConfiguration', '-framework', 'CoreFoundation'].freeze

def reorder_embed_before_thin(runner)
  phases = runner.build_phases
  embed = phases.find { |p| p.respond_to?(:name) && p.name == 'Embed App Extensions' }
  thin = phases.find { |p| p.respond_to?(:name) && p.name == 'Thin Binary' }
  return unless embed && thin
  phases.delete(embed)
  phases.insert(phases.index(thin), embed)
end

if (existing = project.targets.find { |t| t.name == EXT_NAME })
  existing.build_configurations.each { |c| c.build_settings['OTHER_LDFLAGS'] = EXT_LDFLAGS }
  reorder_embed_before_thin(runner)
  project.save
  puts "= #{EXT_NAME} already exists — refreshed settings"
  exit 0
end

ext = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOY, nil, :swift)
group = project.main_group.find_subpath(EXT_NAME, true)
group.set_source_tree('SOURCE_ROOT')
group.set_path(EXT_NAME)
%w[PacketTunnelProvider.swift PlatformBridge.swift Runtime.swift].each do |f|
  ext.add_file_references([group.new_reference(f)])
end
group.new_reference('Info.plist')
group.new_reference("#{EXT_NAME}.entitlements")

ext.build_configurations.each do |c|
  bs = c.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = EXT_ID
  bs['PRODUCT_NAME'] = '$(TARGET_NAME)'
  bs['INFOPLIST_FILE'] = "#{EXT_NAME}/Info.plist"
  bs['CODE_SIGN_ENTITLEMENTS'] = "#{EXT_NAME}/#{EXT_NAME}.entitlements"
  bs['CODE_SIGN_STYLE'] = 'Automatic'
  bs['DEVELOPMENT_TEAM'] = TEAM unless TEAM.empty?
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOY
  bs['SWIFT_VERSION'] = '5.0'
  bs['TARGETED_DEVICE_FAMILY'] = '1,2'
  bs['GENERATE_INFOPLIST_FILE'] = 'NO'
  bs['MARKETING_VERSION'] = '1.0.0'
  bs['CURRENT_PROJECT_VERSION'] = '1'
  bs['ENABLE_BITCODE'] = 'NO'
  bs['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  bs['OTHER_LDFLAGS'] = EXT_LDFLAGS
end

# Libbox is a static archive — LINK only (no embed).
libbox_ref = project.frameworks_group.new_file(File.join(project.project_dir, 'Frameworks', 'Libbox.xcframework'))
ext.frameworks_build_phase.add_file_reference(libbox_ref, true)

runner.add_dependency(ext)
embed = runner.copy_files_build_phases.find { |ph| ph.symbol_dst_subfolder_spec == :plug_ins }
embed ||= runner.new_copy_files_build_phase('Embed App Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
bf = embed.add_file_reference(ext.product_reference, true)
bf.settings = { 'ATTRIBUTES' => %w[CodeSignOnCopy RemoveHeadersOnCopy] }

reorder_embed_before_thin(runner)
project.save
puts "✓ Added #{EXT_NAME} extension. Open Runner.xcworkspace, confirm signing on both targets, and run on a device."
