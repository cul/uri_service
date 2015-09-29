namespace :uri_service do
  namespace :db do
    
    if defined?(Rails)
      desc "Setup"
      task :setup => :environment do
        
        if UriService.client.required_tables_exist?
          puts 'The UriService required tables have already been created.'
          next
        end
        
        puts 'Creating required tables...'
        UriService.client.create_required_tables
        puts 'Done.'
      end
    end
    
  end
end