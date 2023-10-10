require File.expand_path('lib/uri_service/version', __dir__)

Gem::Specification.new do |s|
  s.name        = 'uri_service'
  s.version     = UriService::VERSION
  s.platform    = Gem::Platform::RUBY
  s.date        = '2015-08-28'
  s.summary     = 'A service for registering local URIs and performing both local and remote URI lookups.'
  s.description = 'A service for registering local URIs and performing both local and remote URI lookups.'
  s.authors     = ["Eric O'Hanlon"]
  s.email       = 'elo2112@columbia.edu'
  s.homepage    = 'https://github.com/cul/uri_service'
  s.license     = 'MIT'

  s.add_dependency('activesupport')
  s.add_dependency('connection_pool')
  s.add_dependency('rdf')
  s.add_dependency('rsolr')
  s.add_dependency('sequel', '>= 4.26.0')

  s.add_development_dependency('jettywrapper')
  s.add_development_dependency('rainbow', '~> 3.0')
  s.add_development_dependency('mysql2', '>= 0.3.18')
  s.add_development_dependency('rake', '>= 10.1')
  s.add_development_dependency('rspec', '~>3.1')
  s.add_development_dependency('solr_wrapper')
  # sqlite >= 1.6 is not compatible with arm64 Ruby 2.6.10
  s.add_development_dependency('sqlite3', '< 1.6')

  s.files = Dir['lib/**/*.rb', 'lib/tasks/**/*.rake', 'bin/*', 'LICENSE', '*.md']
  s.require_paths = ['lib']
end
