#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint feitian_reader_sdk.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'feitian_reader_sdk'
  s.version          = '0.0.1'
  s.summary          = 'Flutter plugin for FEITIAN cardreader.'
  s.description      = <<-DESC
Plugin for Flutter for using FEITIAN cardreader over bluetooth with PCSC interface.
                       DESC
  s.homepage         = 'https://www.johnsoncontrols.de/cks'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CKS Systeme GmbH' => 'https://www.johnsoncontrols.de/cks' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 
    'DEFINES_MODULE' => 'YES', 
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../sdk/include"',
    'LIBRARY_SEARCH_PATHS' => '"$(PODS_TARGET_SRCROOT)/../sdk/lib/Release/$(PLATFORM_NAME)"'
    # REMOVED: SWIFT_INCLUDE_PATHS and OTHER_SWIFT_FLAGS
  }
  s.swift_version = '5.0'

  # FEITIAN SDK integration
  s.preserve_paths = "../sdk/**/*"
  
  # Directly vendor the static libraries - this is more reliable than xcconfig
  s.vendored_libraries = [
    "../sdk/lib/Release/iphoneos/libiRockey301_ccid.a"
  ]
  
  s.libraries = ['c++', 'z']
  s.frameworks = ['CoreBluetooth', 'Foundation', 'ExternalAccessory', 'CryptoTokenKit']

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'feitian_reader_sdk_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end