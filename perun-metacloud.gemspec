# coding: utf-8
lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)

require 'metacloud_export/version'

Gem::Specification.new do |gem|
  gem.name          = 'perun-metacloud'
  gem.version       = MetacloudExport::VERSION
  gem.authors       = ['Boris Parak']
  gem.email         = ['parak@cesnet.cz']
  gem.description   = %q{Propagation scripts for integration between OpenNebula and Perun}
  gem.summary       = %q{Propagation scripts for integration between OpenNebula and Perun}
  gem.homepage      = 'https://github.com/arax/perun-metacloud'
  gem.license       = 'Apache License, Version 2.0'

  gem.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  gem.files         = `git ls-files`.split("\n")
  gem.require_paths = ['lib']

  gem.add_dependency 'json'
  gem.add_dependency 'hashie'
  gem.add_dependency 'nokogiri', '~>1.6.0'
  gem.add_dependency 'activesupport', '~>4.0.0'
  gem.add_dependency 'settingslogic'
  gem.add_dependency 'opennebula', '~> 4.4.0'

  gem.required_ruby_version     = '>= 1.9.3'
end
