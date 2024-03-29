# frozen_string_literal: true
require 'open3'
require 'net/http'
require 'rainbow'

namespace :uri_service do
  namespace :docker do
    def docker_compose_file_path
      UriService.root.join("docker/docker-compose.#{ENV['APP_ENV']}.yml")
    end

    def docker_compose_config
      YAML.load_file(docker_compose_file_path)
    end

    def wait_for_solr_cores_to_load
      expected_port = docker_compose_config['services']['solr']['ports'][0].split(':')[0]
      url_to_check = "http://localhost:#{expected_port}/solr/uri_service/admin/system"
      puts "Waiting for Solr to become available (at #{url_to_check})..."
      Timeout.timeout(20, Timeout::Error, 'Timed out during Solr startup check.') do
        loop do
          begin
            sleep 0.25
            status_code = Net::HTTP.get_response(URI(url_to_check)).code
            if status_code == '200' # Solr is ready to receive requests
              puts 'Solr is available.'
              break
            end
          rescue EOFError, Errno::ECONNRESET => e
            # Try again in response to the above error types
            next
          end
        end
      end
    end

    def running?
      status = `docker compose -f #{UriService.root.join(docker_compose_file_path)} ps`
      status.split("n").count > 1
    end

    task :setup_config_files do
      docker_compose_template_dir = UriService.root.join('docker/templates')
      docker_compose_dest_dir = UriService.root.join('docker')
      Dir.foreach(docker_compose_template_dir) do |entry|
        next unless entry.end_with?('.yml')
        src_path = File.join(docker_compose_template_dir, entry)
        dst_path = File.join(docker_compose_dest_dir, entry.gsub('.template', ''))
        if File.exist?(dst_path)
          puts Rainbow("File already exists (skipping): #{dst_path}").blue.bright + "\n"
        else
          FileUtils.cp(src_path, dst_path)
          puts Rainbow("Created file at: #{dst_path}").green
        end
      end
    end

    task :start do
      puts "Starting...\n"
      if running?
        puts "\nAlready running."
      else
        # NOTE: This command rebuilds the container images before each run, to ensure they're
        # always up to date. In most cases, the overhead is minimal if the Dockerfile for an image
        # hasn't changed since the last build.
        `docker compose -f #{docker_compose_file_path} up --build --detach --wait`
        wait_for_solr_cores_to_load
        puts "\nStarted."
      end
    end

    task :stop do
      puts "Stopping...\n"
      if running?
        puts "\n"
        `docker compose -f #{UriService.root.join(docker_compose_file_path)} down`
        puts "\nStopped"
      else
        puts "Already stopped."
      end
    end

    task :restart do
      Rake::Task['uri_service:docker:stop'].invoke
      Rake::Task['uri_service:docker:start'].invoke
    end

    task :status do
      puts running? ? 'Running.' : 'Not running.'
    end

    task :delete_volumes do
      if running?
        puts 'Error: The volumes are currently in use. Please stop the docker services before deleting the volumes.'
        next
      end

      puts Rainbow("This will delete ALL Solr data for the selected app "\
        "environment (#{ENV['APP_ENV']}) and cannot be undone. Please confirm that you want to continue "\
        "by typing the name of the selected Rails environment (#{ENV['APP_ENV']}):").red.bright
      print '> '
      response = ENV['app_env_confirmation'] || $stdin.gets.chomp

      puts ""

      if response != ENV['APP_ENV']
        puts "Aborting because \"#{ENV['APP_ENV']}\" was not entered."
        next
      end

      config = docker_compose_config
      volume_prefix = config['name']
      full_volume_names = config['volumes'].keys.map { |short_name| "#{volume_prefix}_#{short_name}" }

      full_volume_names.map do |full_volume_name|
        if JSON.parse(Open3.capture3("docker volume inspect '#{full_volume_name}'")[0]).length.positive?
          `docker volume rm '#{full_volume_name}'`
          puts Rainbow("Deleted: #{full_volume_name}").green
        else
          puts Rainbow("Skipped: #{full_volume_name} (already deleted)").blue.bright
        end
      end

      puts 'Done.'
    end
  end
end
