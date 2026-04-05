Pod::Spec.new do |s|
  s.name             = 'eixam_connect_flutter'
  s.version          = '0.0.1'
  s.summary          = 'EIXAM Connect Flutter plugin runtime.'
  s.description      = <<-DESC
EIXAM Connect Flutter plugin runtime and Protection Mode platform bridge.
                       DESC
  s.homepage         = 'https://eixam.dev'
  s.license          = { :type => 'Proprietary', :text => 'Internal EIXAM SDK plugin.' }
  s.author           = { 'EIXAM' => 'dev@eixam.dev' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
