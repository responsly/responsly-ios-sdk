Pod::Spec.new do |s|
  s.name             = 'ResponslySDK'
  s.version          = '0.8.0'
  s.summary          = 'Show Responsly surveys inside your iOS app.'
  s.description      = <<-DESC
    The Responsly SDK shows in-app surveys as a bottom sheet, a dialog or full screen.
    Targeting (events, screens, user traits, sampling, frequency) runs on the device.
  DESC
  s.homepage         = 'https://developers.responsly.com'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = 'Responsly'
  s.source           = { :git => 'https://github.com/responsly/responsly-ios-sdk.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.swift_versions   = ['5.9']

  s.source_files     = 'Sources/ResponslySDK/**/*.swift'
  s.resource_bundles = {
    'ResponslySDK' => ['Sources/ResponslySDK/Resources/PrivacyInfo.xcprivacy']
  }
  s.frameworks       = 'UIKit', 'WebKit'
end
