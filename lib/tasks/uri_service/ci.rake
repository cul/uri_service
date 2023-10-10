require 'jettywrapper'
require 'solr_wrapper'
require 'uri_service'

namespace :uri_service do

  begin
    # This code is in a begin/rescue block so that the Rakefile is usable
    # in an environment where RSpec is unavailable (i.e. production).
    require 'rspec/core/rake_task'

    RSpec::Core::RakeTask.new(:rspec) do |spec|
      spec.pattern = FileList['spec/**/*_spec.rb']
      spec.pattern += FileList['spec/*_spec.rb']
      spec.rspec_opts = ['--backtrace'] if ENV['CI']
    end

  rescue LoadError => e
    puts "[Warning] Exception creating rspec rake tasks.  This message can be ignored in environments that intentionally do not pull in the RSpec gem (i.e. production)."
    puts e
  end

  desc "CI build"
  task :ci do
    ENV['APP_ENV'] = 'test'
    Rake::Task["uri_service:ci_prepare"].invoke
    Rake::Task["uri_service:docker:setup_config_files"].invoke
    Rake::Task["uri_service:ci_impl"].invoke
  end

  desc "Preparation steps for the CI run"
  task :ci_prepare do
    # Delete existing test database
    uri_service_config = YAML.load(File.new('spec/fixtures/uri_service_test_config.yml'))['sqlite']
    File.delete(uri_service_config['database']['database']) if File.exists?(uri_service_config['database']['database'])
    FileUtils.mkdir_p(File.dirname(uri_service_config['database']['database']))
    client = UriService::Client.new(uri_service_config)
    client.create_required_tables
    FileUtils.mkdir_p('tmp')
  end

  desc 'CI build just running specs'
  task :ci_impl do
    docker_wrapper do
      duration = Benchmark.realtime do
        Rake::Task["uri_service:rspec"].invoke
      end
      puts "\nCI run finished in #{duration} seconds."
    end
  end

  def docker_wrapper(&block)
    unless ENV['APP_ENV'] == 'test'
      raise 'This task should only be run in the test environment (because it clears docker volumes)'
    end

    # Stop docker if it's currently running (so we can delete any old volumes)
    Rake::Task['uri_service:docker:stop'].invoke
    # Rake tasks must be re-enabled if you want to call them again later during the same run
    Rake::Task['uri_service:docker:stop'].reenable

    ENV['app_env_confirmation'] = ENV['APP_ENV'] # setting this to skip prompt in volume deletion task
    Rake::Task['uri_service:docker:delete_volumes'].invoke

    Rake::Task['uri_service:docker:start'].invoke
    begin
      block.call
    ensure
      Rake::Task['uri_service:docker:stop'].invoke
    end
  end

end
