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
      
      desc "Drop tables and clear solr (Dangerous! Use wisely!)"
      task :drop_tables_and_clear_solr => :environment do
        UriService.client.db.drop_table?(UriService::VOCABULARIES) # Drop table if it exists
        UriService.client.db.drop_table?(UriService::TERMS) # Drop table if it exists
        UriService.client.clear_solr_index
      end
      
    end
    
  end
end