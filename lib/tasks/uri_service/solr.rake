namespace :uri_service do
  namespace :solr do
    
    if defined?(Rails)
      desc "Reindex all terms"
      task :reindex_all_terms => :environment do
        clear = (ENV['CLEAR'].to_s == 'true')
        
        UriService.client.reindex_all_terms(clear, true)
      end
    end
    
  end
end