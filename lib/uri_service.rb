require 'active_support/all'
require 'connection_pool'
require 'rsolr'
require 'sequel'
require 'uri'
require 'yaml'

module UriService
  
  # Constants
  VOCABULARY = :vocabulary
  VOCABULARIES = :vocabularies
  TERM = :term
  TERMS = :terms
  
  # Initialize the main instance of UriService::Client
  # opts format: { 'local_uri_base' => 'http://id.example.com/term/', 'solr' => {...solr config...}, 'database' => {...database config...} }
  def self.init(opts)
    if @client && @client.connected?
      @client.disconnect!
    end
    
    @client = UriService::Client.new(opts)
  end

  def self.client
    return @client
  end
  
  def self.version
    return UriService::VERSION
  end
  
  def self.required_tables
    return [UriService::VOCABULARIES, UriService::TERMS]
  end
  
  # Wrapper around escape method for different versions of RSolr
  def self.solr_escape(str)
    if RSolr.respond_to?(:solr_escape)
      return RSolr.solr_escape(str) # Newer method
    else
      return RSolr.escape(str) # Fall back to older method
    end
  end
  
end

require "uri_service/version"
require "uri_service/client"

require 'uri_service/railtie' if defined?(Rails)