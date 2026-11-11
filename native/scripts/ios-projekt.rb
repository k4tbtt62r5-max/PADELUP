# Ergänzt das von Capacitor erzeugte Xcode-Projekt: Datenschutz-Manifest, Berechtigungen, App-Symbol, Team.
require 'xcodeproj'
require 'fileutils'
require 'json'
team = ENV.fetch('APPLE_TEAM_ID')
root = File.expand_path('../ios/App', __dir__)
vorlagen = File.expand_path('../ios-vorlagen', __dir__)
FileUtils.cp(File.join(vorlagen, 'PrivacyInfo.xcprivacy'), File.join(root, 'App/PrivacyInfo.xcprivacy'))
FileUtils.cp(File.join(vorlagen, 'App.entitlements'), File.join(root, 'App/App.entitlements'))
icon_dir = File.join(root, 'App/Assets.xcassets/AppIcon.appiconset')
Dir.glob(File.join(icon_dir, '*.png')).each { |f| File.delete(f) }
FileUtils.cp(File.join(vorlagen, 'AppIcon-1024.png'), File.join(icon_dir, 'AppIcon-1024.png'))
File.write(File.join(icon_dir, 'Contents.json'), JSON.pretty_generate({
  'images' => [{ 'filename' => 'AppIcon-1024.png', 'idiom' => 'universal', 'platform' => 'ios', 'size' => '1024x1024' }],
  'info' => { 'author' => 'xcode', 'version' => 1 }
}))
# Push: Geräte-Kennung von iOS an Capacitor weiterreichen (fehlt in der Capacitor-Vorlage)
delegate = File.join(root, 'App/AppDelegate.swift')
d = File.read(delegate)
unless d.include?('capacitorDidRegisterForRemoteNotifications')
  hook = <<~SWIFT

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }
  SWIFT
  i = d.rindex('}')
  d = d[0...i] + hook.gsub(/^/, '    ').sub(/\A    \n/, "\n") + "}\n"
  File.write(delegate, d)
  puts 'AppDelegate: Push-Weiterleitung ergänzt'
end

proj = Xcodeproj::Project.open(File.join(root, 'App.xcodeproj'))
target = proj.targets.find { |t| t.name == 'App' }
group = proj.main_group.find_subpath('App', true)
unless group.files.any? { |f| f.path == 'PrivacyInfo.xcprivacy' }
  ref = group.new_reference('PrivacyInfo.xcprivacy')
  target.resources_build_phase.add_file_reference(ref)
end
group.new_reference('App.entitlements') unless group.files.any? { |f| f.path == 'App.entitlements' }
target.build_configurations.each do |c|
  s = c.build_settings
  s['CODE_SIGN_ENTITLEMENTS'] = 'App/App.entitlements'
  s['DEVELOPMENT_TEAM'] = team
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['PRODUCT_BUNDLE_IDENTIFIER'] = 'de.padelup.app'
  s['MARKETING_VERSION'] = '1.0.0'
  s['TARGETED_DEVICE_FAMILY'] = '1'
  s['INFOPLIST_KEY_CFBundleDisplayName'] = 'PadelRun'
end
proj.save
puts 'Xcode-Projekt ergänzt'
