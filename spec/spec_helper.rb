require 'bundler'
Bundler.setup

require "rspec"
require "uri_service"

def absolute_fixture_path(file)
  return File.realpath(File.join(File.dirname(__FILE__), 'fixtures', file))
end
def fixture(file)
  path = absolute_fixture_path(file)
  raise "No fixture file at #{path}" unless File.exists? path
  File.new(path)
end

RSpec.configure do |config|
  config.filter_run focus: true
  config.run_all_when_everything_filtered = true
  
  # Set up UriService singleton instance for use in all tests
  UriService.init(YAML.load(fixture('uri_service_test_config.yml'))['sqlite'])
end