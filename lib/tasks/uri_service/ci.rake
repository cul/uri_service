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
    Rake::Task["uri_service:ci_with_solr_6_wrapper"].invoke
    #Rake::Task["uri_service:ci_with_jetty_wrapper"].invoke
  end
  
  desc "Preparation steps for the CI run"
  task :ci_prepare do
    # Delete existing test database
    uri_service_config = YAML.load(File.new('spec/fixtures/uri_service_test_config.yml'))['sqlite']
    File.delete(uri_service_config['database']['database']) if File.exists?(uri_service_config['database']['database'])
    FileUtils.mkdir_p(File.dirname(uri_service_config['database']['database']))
    client = UriService::Client.new(uri_service_config)
    client.create_required_tables
  end
  
  desc "CI build (using SolrWrapper and Solr 6)"
  task :ci_with_solr_6_wrapper do
    solr_version = '6.3.0'
    instance_dir = File.join('tmp', "solr-#{solr_version}")
    FileUtils.rm_rf(instance_dir)
    
    puts "Unpacking and starting solr...\n"
    SolrWrapper.wrap({
      port: 9983,
      version: solr_version,
      verbose: false,
      mirror_url: 'http://lib-solr-mirror.princeton.edu/dist/',
      managed: true,
      download_path: File.join('tmp', "solr-#{solr_version}.zip"),
      instance_dir: File.join('tmp', "solr-#{solr_version}"),
    }) do |solr_wrapper_instance|
      
      # Create collection
      solr_wrapper_instance.with_collection(name: 'uri_service_test', dir: File.join('spec/fixtures', 'uri_service_test_cores/uri_service_test-solr6-conf')) do |collection_name|
        Rake::Task["uri_service:ci_prepare"].invoke
        Rake::Task["uri_service:rspec"].invoke
      end
      
      puts 'Stopping solr...'
    end
  end
  
  desc "CI build (using JettyWrapper)"
  task :ci_with_jetty_wrapper do
    
    Jettywrapper.url = "https://github.com/cul/hydra-jetty/archive/solr-only.zip"
    Jettywrapper.jetty_dir = File.join('tmp', 'jetty-test')
  
    unless File.exists?(Jettywrapper.jetty_dir)
      puts "\n" + 'No test jetty found.  Will download / unzip a copy now.' + "\n"
    end
    
    Rake::Task["jetty:clean"].invoke # Clear and recreate previous jetty directory
    
    # Copy solr core fixture to new solr instance
    FileUtils.cp_r('spec/fixtures/uri_service_test_cores/uri_service_test', File.join(Jettywrapper.jetty_dir, 'solr'))
    # Update solr.xml configuration file so that it recognizes this code
    solr_xml_data = File.read(File.join(Jettywrapper.jetty_dir, 'solr/solr.xml'))
    solr_xml_data.gsub!('</cores>', '  <core name="uri_service_test" instanceDir="uri_service_test" />' + "\n" + '  </cores>')
    File.open(File.join(Jettywrapper.jetty_dir, 'solr/solr.xml'), 'w') { |file| file.write(solr_xml_data) }
    
    jetty_params = Jettywrapper.load_config.merge({
      jetty_home: Jettywrapper.jetty_dir,
      solr_home: 'solr',
      startup_wait: 75,
      jetty_port: 9983,
      java_version: '>= 1.8',
      java_opts: ["-XX:MaxPermSize=128m", "-Xmx256m"]
    })
    error = Jettywrapper.wrap(jetty_params) do
      Rake::Task["uri_service:ci_prepare"].invoke
      Rake::Task["uri_service:rspec"].invoke
    end
    raise "test failures: #{error}" if error
    
  end

end