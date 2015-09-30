class UriService::Client
  
  attr_reader :db, :rsolr_pool, :local_uri_base
  
  ALPHANUMERIC_UNDERSCORE_KEY_REGEX = /\A[a-z]+[a-z0-9_]*\z/
  VALID_URI_REGEX = /\A#{URI::regexp(['http', 'https'])}\z/
  
  def initialize(opts)
    raise UriService::InvalidOptsError, "Must supply opts['local_uri_base'] to initialize method." if opts['local_uri_base'].nil?
    raise UriService::InvalidOptsError, "Must supply opts['database'] to initialize method." if opts['database'].nil?
    raise UriService::InvalidOptsError, "Must supply opts['solr'] to initialize method." if opts['solr'].nil?
    
    # Set local_uri_base
    @local_uri_base = opts['local_uri_base']
    
    # Create DB connection pool
    @db = Sequel.connect(opts['database'])
    
    # Create Solr connection pool
    @rsolr_pool = ConnectionPool.new( size: opts['solr']['pool_size'], timeout: (opts['solr']['pool_timeout'].to_f/1000.to_f) ) { RSolr.connect(:url => opts['solr']['url']) }
  end
  
  def disconnect!
    unless @db.nil?
      db_reference = @db
      @db = nil
      db_reference.disconnect
    end
    
    unless @rsolr_pool.nil?
      rsolr_pool_reference = @rsolr_pool
      @rsolr_pool = nil
      rsolr_pool_reference.shutdown{|rsolr|}  # connection_pool gem docs say that shutting down is
                                              # optional and pool would be garbage collected anyway,
                                              # but this doesn't hurt.
    end
  end
  
  def connected?
    return false if @db.nil? || @rsolr_pool.nil?
    
    begin
      self.test_connection
      return true
    rescue Sequel::DatabaseConnectionError, Errno::ECONNREFUSED
      return false
    end
  end
  
  def test_connection
    @db.test_connection # Raises Sequel::DatabaseConnectionError if connection didn't work
    @rsolr_pool.with do |rsolr|
      rsolr.get('admin/ping') # Raises Errno::ECONNREFUSED if connection didn't work
    end
  end
  
  def required_tables_exist?
    return (UriService.required_tables - @db.tables).length == 0
  end
  
  def create_required_tables
    current_tables = @db.tables
    
    unless current_tables.include?(UriService::VOCABULARIES)
      @db.create_table UriService::VOCABULARIES do |t|
        primary_key :id
        String :string_key, size: 255, index: true, unique: true
        String :display_label, size: 255
      end
    else
      puts 'Skipped creation of table ' + UriService::VOCABULARIES.to_s + ' because it already exists.'
    end
    
    unless current_tables.include?(UriService::TERMS)
      @db.create_table UriService::TERMS do |t|
        primary_key :id
        String :vocabulary_string_key, size: 255, index: true
        String :uri, text: true # This needs to be a text field because utf8 strings cannot be our desired 2000 characters long in MySQL. uri_hash will be used to verify uniqueness.
        String :uri_hash, fixed: true, size: 64, unique: true
        String :value, text: true
        TrueClass :is_local, default: false
        String :additional_fields, text: true
      end
    else
      puts 'Skipped creation of table ' + UriService::TERMS.to_s + ' because it already exists.'
    end
  end
  
  ##################
  # Create methods #
  ##################
  
  def create_vocabulary(string_key, display_label)
    if string_key.to_s == 'all'
      # Note: There isn't currently a use case for searching across 'all' vocabularies, but I'm leaving this restriction as a placeholder in case that changes.
      raise UriService::InvalidVocabularyStringKeyError, 'The value "all" is a reserved word and cannot be used as the string_key value for a vocabulary.'
    end
    unless string_key =~ ALPHANUMERIC_UNDERSCORE_KEY_REGEX
      raise UriService::InvalidVocabularyStringKeyError, "Invalid key (can only include lower case letters, numbers or underscores, but cannot start with an underscore): " + string_key
    end
    
    @db.transaction do
      begin
        @db[UriService::VOCABULARIES].insert(string_key: string_key, display_label: display_label)
      rescue Sequel::UniqueConstraintViolation
        raise UriService::ExistingVocabularyStringKeyError, "A vocabulary already exists with string key: " + string_key
      end
    end
    
  end
  
  # Creates a new term.
  def create_term(vocabulary_string_key, value, term_uri, additional_fields={})
    self.create_term_impl(vocabulary_string_key, value, term_uri, additional_fields, false)
  end
  
  # Creates a new local term, auto-generating a URI
  def create_local_term(vocabulary_string_key, value, additional_fields={})
  
    # Create a new URI for this local term, using the @local_uri_base
    term_uri = URI(@local_uri_base)
    term_uri.path = '/' + File.join(vocabulary_string_key, SecureRandom.uuid) # Generate random UUID for local URI
    term_uri = term_uri.to_s
    
    # Getting a duplicate UUID from SecureRandom.uuid is EXTREMELY unlikely, but we'll account for it just in case (by making a few more attempts).
    5.times {
      begin
        self.create_term_impl(vocabulary_string_key, value, term_uri, additional_fields, true)
        break
      rescue UriService::ExistingUriError
        if defined?(Rails)
          Rails.logger.error "UriService generated a duplicate random UUID (via SecureRandom.uuid) and will now attempt to create another.  This type of problem is EXTREMELY rare."
        end
      end
    }
  end
  
  def create_term_impl(vocabulary_string_key, value, term_uri, additional_fields, is_local)
    
    #Ensure that vocabulary with vocabulary_string_key exists
    if self.find_vocabulary(vocabulary_string_key).nil?
      raise UriService::NonExistentVocabularyError, "There is no vocabulary with string key: " + vocabulary_string_key
    end
    unless term_uri =~ VALID_URI_REGEX
      raise UriService::InvalidUriError, "Invalid URI supplied: #{term_uri}, with result #{(VALID_URI_REGEX.match(term_uri)).to_s}"
    end
    validate_additional_fields(additional_fields) # This method call raises an error if an invalid additional_field key is supplied
    
    @db.transaction do
      begin
        @db[UriService::TERMS].insert(
          is_local: is_local,
          uri: term_uri,
          uri_hash: Digest::SHA256.hexdigest(term_uri),
          value: value,
          vocabulary_string_key: vocabulary_string_key,
          additional_fields: JSON.generate(additional_fields)
        )
        
        self.send_term_to_solr(@db[UriService::TERMS].where(uri: term_uri).first)
        
      rescue Sequel::UniqueConstraintViolation
        raise UriService::ExistingUriError, "A term already exists with uri: " + term_uri + " (conflict found via uri_hash check)"
      end
    end
    
  end
  
  def term_db_row_to_solr_doc(term_row_data_from_db)
    doc = {}
    doc['uri'] = term_row_data_from_db[:uri]
    doc['value'] = term_row_data_from_db[:value]
    doc['is_local_bsi'] = term_row_data_from_db[:is_local]
    doc['vocabulary_string_key_ssi'] = term_row_data_from_db[:vocabulary_string_key]
    JSON.parse(term_row_data_from_db[:additional_fields]).each do |key, val|
      doc[key + '_ssi'] = val
    end
    
    return doc
  end
  
  # Index the DB row term data into solr
  def send_term_to_solr(term_row_data_from_db, commit=true)
    
    @rsolr_pool.with do |rsolr|
      rsolr.add(term_db_row_to_solr_doc(term_row_data_from_db))
      rsolr.commit if commit
    end
  end
  
  # Validates additional_fields and verifies that no reserved words are supplied
  def validate_additional_fields(additional_fields)
    reserved_keys = ['is_local', 'uri', 'value', 'vocabulary_string_key']
    additional_fields.each do |key, value|
      if reserved_keys.include?(key.to_s)
        raise UriService::InvalidAdditionalFieldKeyError, "Cannot supply the key \"#{key.to_s}\" as an additional field because it is a reserved key."
      end
      unless key =~ ALPHANUMERIC_UNDERSCORE_KEY_REGEX
        raise UriService::InvalidAdditionalFieldKeyError, "Invalid key (can only include lower case letters, numbers or underscores, but cannot start with an underscore): " + key
      end
    end
  end
  
  ################
  # Find methods #
  ################
  
  def find_vocabulary(vocabulary_string_key)
    @db[UriService::VOCABULARIES].where(string_key: vocabulary_string_key).first
  end
  
  def find_term_by_uri(uri)
    UriService.client.rsolr_pool.with do |rsolr|
      response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + UriService.solr_escape(uri) })
      if response['response']['numFound'] == 1
        return term_solr_doc_to_term_hash(response['response']['docs'].first)
      end
    end
    return nil
  end
  
  def term_solr_doc_to_term_hash(term_solr_doc)
    term_hash = {}
    term_solr_doc.each do |key, value|
      next if ['_version_', 'timestamp', 'score'].include?(key) # Skip certain automatically added fields that we don't care about
      term_hash[key.gsub(/_[^_]+$/, '')] = value # Remove trailing '_si', '_bi', etc. if present
    end
    return term_hash
  end
  
  def find_terms_by_query(vocabulary_string_key, value_query, limit=10, start=0)
    terms_to_return = []
    UriService.client.rsolr_pool.with do |rsolr|
      
      solr_params = {
        :q => value_query == '' ? '*' : UriService.solr_escape(value_query),
        :fq => 'vocabulary_string_key_ssi:' + UriService.solr_escape(vocabulary_string_key),
        :rows => limit,
        :start => start
      }
      
      response = rsolr.get('suggest', params: solr_params)
      if response['response']['numFound'] > 0
        response['response']['docs'].each do |doc|
          terms_to_return << term_solr_doc_to_term_hash(doc)
        end
      end
    end
    return terms_to_return
  end
  
  ##################
  # Delete methods #
  ##################
  
  def delete_vocabulary(vocabulary_string_key)
    @db[UriService::VOCABULARIES].where(string_key: vocabulary_string_key).delete
  end
  
  def delete_term(term_uri, commit=true)
    @db.transaction do
      @db[UriService::TERMS].where(uri: term_uri).delete
      @rsolr_pool.with do |rsolr|
        rsolr.delete_by_query('uri:' + UriService.solr_escape(term_uri))
        rsolr.commit if commit
      end
    end
  end
  
  ##################
  # Update methods #
  ##################
  
  def update_vocabulary(string_key, new_display_label)
    dataset = @db[UriService::VOCABULARIES].where(string_key: string_key)
    raise UriService::NonExistentVocabularyError, "No vocabulary found with string_key: " + string_key if dataset.count == 0
    
    @db.transaction do
      dataset.update(display_label: new_display_label)
    end
  end
  
  def update_term_value(term_uri, value)
    self.update_term_impl(term_uri, value, {}, true)
  end
  
  def update_term_additional_fields(term_uri, additional_fields, merge=false)
    self.update_term_impl(term_uri, nil, additional_fields, merge)
  end
  
  def update_term_impl(term_uri, value, additional_fields, merge_additional_fields)
    
    dataset = @db[UriService::TERMS].where(uri: term_uri)
    raise UriService::NonExistentUriError, "No term found with uri: " + term_uri if dataset.count == 0
    validate_additional_fields(additional_fields)
      
    term = dataset.first
    term_additional_fields = term['additional_fields'].nil? ? {} : JSON.parse(term['additional_fields'])
    
    if merge_additional_fields
      term_additional_fields.merge!(additional_fields)
      term_additional_fields.delete_if { |k, v| v.nil? } # Delete nil values. This is a way to clear data in additional_fields.
    else
      term_additional_fields = additional_fields
    end
    
    new_data = {}
    new_data[:value] = value unless value.nil?
    new_data[:additional_fields] = JSON.generate(term_additional_fields)
    
    @db.transaction do
      dataset.update(new_data)
      self.send_term_to_solr(@db[UriService::TERMS].where(uri: term_uri).first)
    end
    
  end
  
end

class UriService::InvalidAdditionalFieldKeyError < StandardError;end
class UriService::InvalidVocabularyStringKeyError < StandardError;end
class UriService::InvalidOptsError < StandardError;end
class UriService::InvalidUriError < StandardError;end
class UriService::ExistingUriError < StandardError;end
class UriService::ExistingVocabularyStringKeyError < StandardError;end
class UriService::NonExistentUriError < StandardError;end
class UriService::NonExistentVocabularyError < StandardError;end
