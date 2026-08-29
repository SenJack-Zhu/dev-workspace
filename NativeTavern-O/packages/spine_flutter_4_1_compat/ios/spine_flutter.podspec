#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint spine_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'spine_flutter'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{cpp}'
  s.preserve_paths   = 'spine_flutter.exports'
  s.xcconfig = { 'HEADER_SEARCH_PATHS' => '"' + __dir__ + '/Classes/spine-cpp/include"' }
  s.dependency 'Flutter'
  s.platform = :ios, '9.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  # Dart resolves the statically linked API with DynamicLibrary.process().
  # Keep the bridge object in Runner even though native code does not call it,
  # and retain only the FFI bridge symbols in the dynamic export table after
  # Release stripping.
  s.user_target_xcconfig = {
    'STRIP_STYLE' => 'non-global',
    'OTHER_LDFLAGS' => '$(inherited) -Wl,-u,_spine_major_version -Wl,-export_dynamic -Wl,-exported_symbols_list,$(PODS_ROOT)/../.symlinks/plugins/spine_flutter/ios/spine_flutter.exports'
  }
  s.swift_version = '5.0'
end
