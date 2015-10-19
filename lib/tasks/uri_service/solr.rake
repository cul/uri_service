namespace :uri_service do
  namespace :solr do
    
    if defined?(Rails)
      desc "Reindex all terms"
      task :reindex_all_terms => :environment do
        UriService.client.reindex_all_terms(true)
      end
    end
    
  end
end