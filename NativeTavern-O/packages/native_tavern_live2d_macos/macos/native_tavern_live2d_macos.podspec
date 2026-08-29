Pod::Spec.new do |s|
  s.name             = 'native_tavern_live2d_macos'
  s.version          = '0.1.0'
  s.summary          = 'NativeTavern macOS bridge for Live2D Cubism SDK for Native.'
  s.description      = 'Renders Live2D Cubism models through Flutter macOS textures.'
  s.homepage         = 'https://github.com/NativeTavern/NativeTavern'
  s.license          = { :file => 'licenses/flutter_live2d-BSD-3-Clause.txt' }
  s.author           = { 'NativeTavern' => 'NativeTavern' }
  s.source           = { :path => '.' }
  s.platform         = :osx, '11.0'
  s.swift_version    = '5.0'

  s.source_files = [
    'Classes/**/*.{h,m,mm,swift}',
    'CubismFramework/**/*.{h,hpp,cpp}',
  ]
  s.public_header_files = [
    'Classes/Live2DWrapper.h',
    'Classes/Live2DMacOSTexture.h',
  ]
  s.private_header_files = [
    'Classes/stb_image.h',
    'CubismFramework/**/*.{h,hpp}',
  ]
  s.vendored_libraries = 'Libs/libLive2DCubismCore.dylib'
  s.resource_bundles = {
    'native_tavern_live2d_macos' => [
      'CubismFramework/Rendering/OpenGL/Shaders/Standard/*.{vert,frag}',
      'licenses/*',
    ]
  }
  s.preserve_paths = ['licenses/*']

  s.frameworks = ['AppKit', 'CoreVideo', 'Foundation', 'OpenGL']
  s.libraries = ['c++', 'z']
  s.dependency 'FlutterMacOS'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++14',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => [
      '$(PODS_TARGET_SRCROOT)/CubismFramework',
      '$(PODS_TARGET_SRCROOT)/CubismCore/include',
      '$(PODS_TARGET_SRCROOT)/Classes',
    ].join(' '),
    # Cubism only uses this flag to skip its desktop GLEW include. The macOS
    # system OpenGL headers expose the functions used by the renderer.
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) CSM_TARGET_MAC_GL=1 CSM_TARGET_COCOS=1',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
  }
end
