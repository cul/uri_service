class UriService::Client
  
  attr_reader :db, :rsolr_pool, :local_uri_base, :temporary_uri_base
  
  ALPHANUMERIC_UNDERSCORE_KEY_REGEX = /\A[a-z]+[a-z0-9_]*\z/
  CORE_FIELD_NAMES = ['uri', 'vocabulary_string_key', 'value', 'authority', 'type', 'internal_id']
  VALID_TYPES = [UriService::TermType::EXTERNAL, UriService::TermType::LOCAL, UriService::TermType::TEMPORARY]
  
  def initialize(opts)
    raise UriService::InvalidOptsError, "Must supply opts['local_uri_base'] to initialize method." if opts['local_uri_base'].nil?
    raise UriService::InvalidOptsError, "Must supply opts['temporary_uri_base'] to initialize method." if opts['temporary_uri_base'].nil?
    raise UriService::InvalidOptsError, "Must supply opts['database'] to initialize method." if opts['database'].nil?
    raise UriService::InvalidOptsError, "Must supply opts['solr'] to initialize method." if opts['solr'].nil?
    
    # Set local_uri_base and temporary_uri_base
    @local_uri_base = opts['local_uri_base']
    @temporary_uri_base = opts['temporary_uri_base']
    
    # Create DB connection pool
    @db = Sequel.connect(opts['database'])
    
    # Create Solr connection pool
    @rsolr_pool = ConnectionPool.new( size: opts['solr']['pool_size'], timeout: (opts['solr']['pool_timeout'].to_f/1000.to_f) ) { RSolr.connect(:url => opts['solr']['url']) }
  end
  
  def reindex_all_terms(clear=false, print_progress_to_console=false)
    self.handle_database_disconnect do
      
      if print_progress_to_console
        puts "Getting database term count..."
        total = @db[UriService::TERMS].count
        reindex_counter = 0
        puts "Number of terms to index: #{total.to_s}"
        puts ""
      end
      
      if clear
        @rsolr_pool.with do |rsolr|
          rsolr.delete_by_query('*:*');
        end
      end
      
      # Need to use unambiguous order when using paged_each, so we choose to order by DB :id
      @db[UriService::TERMS].order(:id).paged_each(:rows_per_fetch=>100) do |term_db_row|
        self.send_term_to_solr(
          term_db_row[:vocabulary_string_key],
          term_db_row[:value],
          term_db_row[:uri],
          term_db_row[:authority],
          JSON.parse(term_db_row[:additional_fields]),
          term_db_row[:type],
          term_db_row[:id],
        false)
        
        if print_progress_to_console
          reindex_counter += 1
          print "\rIndexed #{reindex_counter.to_s} of #{total.to_s}"
        end
      end
      
      puts "\n" + "Committing solr updates..." if print_progress_to_console
      self.do_solr_commit
      puts "Done." if print_progress_to_console
    end
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
    self.handle_database_disconnect do
    
      current_tables = @db.tables
      
      unless current_tables.include?(UriService::VOCABULARIES)
        @db.create_table UriService::VOCABULARIES do |t|
          primary_key :id
          String :string_key, size: 255, index: true, unique: true
          String :display_label, size: 255
        end
        puts 'Created table: ' + UriService::VOCABULARIES.to_s
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
          String :value_hash, fixed: true, size: 64
          String :type, null: false
          String :authority, size: 255, index: true
          String :additional_fields, text: true
        end
        puts 'Created table: ' + UriService::TERMS.to_s
      else
        puts 'Skipped creation of table ' + UriService::TERMS.to_s + ' because it already exists.'
      end
      
    end
  end
  
  ##################
  # Create methods #
  ##################
  
  def create_vocabulary(string_key, display_label)
    self.handle_database_disconnect do
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
  end
  
  # Creates a new term
  def create_term(type, opts)
    raise UriService::InvalidTermTypeError, 'Invalid type: ' + type unless VALID_TYPES.include?(type)
    
    vocabulary_string_key = opts.delete(:vocabulary_string_key)
    value = opts.delete(:value)
    uri = opts.delete(:uri)
    authority = opts.has_key?(:authority) ? opts.delete(:authority) : ''
    authority = '' if authority.nil?
    additional_fields = opts.delete(:additional_fields) || {}
    
    if type == UriService::TermType::EXTERNAL
      # URI is required
      raise UriService::InvalidOptsError, "A uri must be supplied for terms of type #{type}." if uri.nil?
      
      return create_term_impl(type, vocabulary_string_key, value, uri, authority, additional_fields)
    else
      # URI should not be present
      raise UriService::InvalidOptsError, "A uri cannot supplied for term type: #{type}" unless uri.nil?
      
      if type == UriService::TermType::TEMPORARY
        # No two TEMPORARY terms within the same vocabulary can have the same value, so we generate a unique URI from a hash of the (vocabulary_string_key + value) to ensure uniqueness.
        uri = self.generate_uri_for_temporary_term(vocabulary_string_key, value)
        return create_term_impl(type, vocabulary_string_key, value, uri, authority, additional_fields)
      elsif type == UriService::TermType::LOCAL
        5.times {
          # We generate a unique URI for a local term from a UUID generator.
          # Getting a duplicate UUID from a call to SecureRandom.uuid is EXTREMELY unlikely,
          # but we'll account for it just in case by being ready to make multiple attempts.
          begin
            # Generate new URI for LOCAL and TEMPORARY terms
            uri = URI(@local_uri_base)
            uri.path += SecureRandom.uuid # Generate random UUID for local URI
            uri = uri.to_s
            return create_term_impl(type, vocabulary_string_key, value, uri, authority, additional_fields)
          rescue UriService::ExistingUriError
            next
          end
        }
        # Probabilistically, the error below should never be raised.
        raise UriService::CouldNotGenerateUriError, "UriService generated a duplicate random UUID (via SecureRandom.uuid) too many times in a row.  Probabilistically, this should never happen."
      end
      
    end
  end
  
  def generate_uri_for_temporary_term(vocabulary_string_key, term_value)
    uri = URI(@temporary_uri_base + Digest::SHA256.hexdigest(vocabulary_string_key + term_value))
    return uri.to_s
  end
  
  def generate_frozen_term_hash(vocabulary_string_key, value, uri, authority, additional_fields, type, internal_id)
    hash_to_return = {}
    hash_to_return['uri'] = uri
    hash_to_return['value'] = value
    hash_to_return['type'] = type
    hash_to_return['authority'] = authority unless authority == ''
    hash_to_return['vocabulary_string_key'] = vocabulary_string_key
    hash_to_return['internal_id'] = internal_id
    
    additional_fields.each do |key, val|
      hash_to_return[key] = val
    end
    
    # Delete nil values
    hash_to_return.delete_if { |k, v| v.nil? }
    
    # Freeze hash
    hash_to_return.freeze # To make this a read-only hash
    
    return hash_to_return
  end
  
  def create_term_solr_doc(vocabulary_string_key, value, uri, authority, additional_fields, type, internal_id)
    doc = {}
    doc['uri'] = uri
    doc['value'] = value
    doc['type'] = type
    doc['vocabulary_string_key'] = vocabulary_string_key
    doc['authority'] = authority
    doc['internal_id'] = internal_id
    
    doc['additional_fields'] = JSON.generate(additional_fields)
    
    return doc
  end
  
  # Index the DB row term data into solr
  def send_term_to_solr(vocabulary_string_key, value, uri, authority, additional_fields, type, internal_id, commit=true)
    doc = create_term_solr_doc(vocabulary_string_key, value, uri, authority, additional_fields, type, internal_id)
    @rsolr_pool.with do |rsolr|
      rsolr.add(doc)
      rsolr.commit if commit
    end
  end
  
  # Validates additional_fields and verifies that no reserved words are supplied
  def validate_additional_field_keys(additional_fields)
    additional_fields.each do |key, value|
      if CORE_FIELD_NAMES.include?(key.to_s)
        raise UriService::InvalidAdditionalFieldKeyError, "Cannot supply the key \"#{key.to_s}\" as an additional field because it is a reserved key."
      end
      unless key.to_s =~ ALPHANUMERIC_UNDERSCORE_KEY_REGEX
        raise UriService::InvalidAdditionalFieldKeyError, "Invalid key (can only include lower case letters, numbers or underscores, but cannot start with an underscore): " + key
      end
    end
  end
  
  ################
  # Find methods #
  ################
  
  def find_vocabulary(vocabulary_string_key)
    self.handle_database_disconnect do
      @db[UriService::VOCABULARIES].where(string_key: vocabulary_string_key).first
    end
  end
  
  # Finds the term with the given uri
  def find_term_by_uri(uri)
    results = self.find_terms_where({uri: uri}, 1)
    return results.length == 1 ? results.first : nil
  end
  
  # Finds the term with the given uri
  def find_term_by_internal_id(id)
    results = self.find_terms_where({internal_id: id}, 1)
    return results.length == 1 ? results.first : nil
  end
  
  # Finds terms that match the specified conditions
  def find_terms_where(opts, limit=10)
    fqs = []
    
    # Only search on allowed fields
    unsupported_search_fields = opts.map{|key, val| key.to_s} - CORE_FIELD_NAMES
    raise UriService::UnsupportedSearchFieldError, "Unsupported search fields: #{unsupported_search_fields.join(', ')}" if unsupported_search_fields.present?
    
    opts.each do |field_name, val|
      fqs << (field_name.to_s + ':"' + UriService.solr_escape(val.to_s) + '"')
    end
    
    @rsolr_pool.with do |rsolr|
      response = rsolr.get('select', params: {
        :q => '*:*',
        :fq => fqs,
        :rows => limit,
        :sort => 'value_ssort asc, uri asc' # For consistent sorting
        # Note: We don't sort by solr score because solr fq searches don't factor into the score
      })
      if response['response']['docs'].length > 0
        arr_to_return = []
        response['response']['docs'].each do |doc|
          arr_to_return << term_solr_doc_to_frozen_term_hash(doc)
        end
        return arr_to_return
      else
        return []
      end
    end
  end
  
  def term_solr_doc_to_frozen_term_hash(term_solr_doc)
    
    uri = term_solr_doc.delete('uri')
    vocabulary_string_key = term_solr_doc.delete('vocabulary_string_key')
    value = term_solr_doc.delete('value')
    authority = term_solr_doc.delete('authority')
    type = term_solr_doc.delete('type')
    additional_fields = JSON.parse(term_solr_doc.delete('additional_fields'))
    internal_id = term_solr_doc.delete('internal_id')
    
    return generate_frozen_term_hash(vocabulary_string_key, value, uri, authority, additional_fields, type, internal_id)
  end
  
  def find_terms_by_query(vocabulary_string_key, value_query, limit=10, start=0)
    
    if value_query.blank?
      return self.list_terms(vocabulary_string_key, limit, start)
    end
    
    terms_to_return = []
    @rsolr_pool.with do |rsolr|
      
      solr_params = {
        :q => UriService.solr_escape(value_query),
        :fq => 'vocabulary_string_key:' + UriService.solr_escape(vocabulary_string_key),
        :rows => limit,
        :start => start,
        :sort => 'score desc, value_ssort asc, uri asc' # For consistent sorting
      }
      
      if value_query.length < 3
        # For efficiency, we only do whole term matches for queries < 3 characters
        solr_params[:qf] = 'value_suggest'
        solr_params[:pf] = 'value_suggest'
      end
        
      response = rsolr.get('suggest', params: solr_params)
      
      if response['response']['numFound'] > 0
        response['response']['docs'].each do |doc|
          terms_to_return << term_solr_doc_to_frozen_term_hash(doc)
        end
      end
    end
    return terms_to_return
  end
  
  ################
  # List methods #
  ################
  
  # Lists vocabularies alphabetically (by string key) and supports paging through results.
  def list_vocabularies(limit=10, start=0)
    self.handle_database_disconnect do
      db_rows = @db[UriService::VOCABULARIES].order(:string_key).limit(limit, start)
      return db_rows.map{|row| row.except(:id).stringify_keys!}
    end
  end
  
  # Lists terms alphabetically and supports paging through results.
  # Useful for browsing through a term list without a query.
  def list_terms(vocabulary_string_key, limit=10, start=0)
    terms_to_return = []
    @rsolr_pool.with do |rsolr|
      
      solr_params = {
        :fq => 'vocabulary_string_key:' + UriService.solr_escape(vocabulary_string_key),
        :rows => limit,
        :start => start,
        :sort => 'value_ssort asc, uri asc' # Include 'uri asc' as part of sort to ensure consistent sorting
      }
      
      response = rsolr.get('select', params: solr_params)
      if response['response']['numFound'] > 0
        response['response']['docs'].each do |doc|
          terms_to_return << term_solr_doc_to_frozen_term_hash(doc)
        end
      end
    end
    return terms_to_return
  end
  
  ##################
  # Delete methods #
  ##################
  
  def delete_vocabulary(vocabulary_string_key)
    self.handle_database_disconnect do
      @db[UriService::VOCABULARIES].where(string_key: vocabulary_string_key).delete
    end
  end
  
  def delete_term(uri, commit=true)
    self.handle_database_disconnect do
      @db.transaction do
        @db[UriService::TERMS].where(uri: uri).delete
        @rsolr_pool.with do |rsolr|
          rsolr.delete_by_query('uri:' + UriService.solr_escape(uri))
          rsolr.commit if commit
        end
      end
    end
  end
  
  ##################
  # Update methods #
  ##################
  
  def update_vocabulary(string_key, new_display_label)
    self.handle_database_disconnect do
      dataset = @db[UriService::VOCABULARIES].where(string_key: string_key)
      raise UriService::NonExistentVocabularyError, "No vocabulary found with string_key: " + string_key if dataset.count == 0
      
      @db.transaction do
        dataset.update(display_label: new_display_label)
      end
    end
  end
  
  # opts format: {:value => 'new value', :authority => 'newauthority', :additional_fields => {'key' => 'value'}}
  def update_term(uri, opts, merge_additional_fields=true)
    self.handle_database_disconnect do
      term_db_row = @db[UriService::TERMS].first(uri: uri)
      raise UriService::NonExistentUriError, "No term found with uri: " + uri if term_db_row.nil?
      
      new_value = opts[:value] || term_db_row[:value]
      new_authority = opts[:authority] || term_db_row[:authority]
      new_additional_fields = term_db_row[:additional_fields].nil? ? {} : JSON.parse(term_db_row[:additional_fields])
      
      if term_db_row[:type] == UriService::TermType::TEMPORARY && new_value != term_db_row[:value]
        # TEMPORARY terms cannot have their values changed, but it is possible to update other fields
        raise UriService::CannotChangeTemporaryTermValue, "The value of a temporary term cannot be changed. Delete unusued temporary terms or create a new one with a different value."
      end
      
      unless opts[:additional_fields].nil?
        if merge_additional_fields
          new_additional_fields.merge!(opts[:additional_fields])
          new_additional_fields.delete_if { |k, v| v.nil? } # Delete nil values. This is a way to clear data in additional_fields.
        else
          new_additional_fields = opts[:additional_fields]
        end
      end
      validate_additional_field_keys(new_additional_fields)
      
      @db.transaction do
        @db[UriService::TERMS].where(uri: uri).update(value: new_value, value_hash: Digest::SHA256.hexdigest(new_value), authority: new_authority, additional_fields: JSON.generate(new_additional_fields))
        self.send_term_to_solr(term_db_row[:vocabulary_string_key], new_value, uri, new_authority, new_additional_fields, term_db_row[:type], term_db_row[:id])
      end
      
      return generate_frozen_term_hash(term_db_row[:vocabulary_string_key], new_value, uri, new_authority, new_additional_fields, term_db_row[:type], term_db_row[:id])
    end
  end
  
  def handle_database_disconnect
    tries ||= 3
    begin
      yield
    rescue Sequel::DatabaseDisconnectError
      tries -= 1
      retry unless tries == 0
    end
  end
  
  def do_solr_commit
    @rsolr_pool.with do |rsolr|
      rsolr.commit
    end
  end
  
  def clear_solr_index
    @rsolr_pool.with do |rsolr|
      rsolr.delete_by_query('*:*');
      rsolr.commit
    end
  end
  
  #########################
  # BEGIN PRIVATE METHODS #
  #########################
  
  private
  
  # Backing implementation for actual term creation in db/solr.
  # - Performs some data validations.
  # - Ensures uniqueness of URIs in database.
  # - Returns an existing TEMPORARY term if a user attempts to
  #   create a new TEMPORARY term with an existing value/vocabulary combo,
  #   also adding non-existent supplied additional_fields to the existing temporary term.
  def create_term_impl(type, vocabulary_string_key, value, uri, authority, additional_fields)
    
    raise UriService::InvalidTermTypeError, 'Invalid type: ' + type unless VALID_TYPES.include?(type)
    
    self.handle_database_disconnect do
      
      if type == UriService::TermType::TEMPORARY
        # If this is a TEMPORARY term, we need to ensure that the temporary
        # passed in URI is a hash of the vocabulary + value, just in case this
        # method is ever called directly instead of through the create_term
        # wrapper method. This is to ensure that our expectations about the
        # uniqueness of TEMPORARY term values is never violated.
        unless uri == self.generate_uri_for_temporary_term(vocabulary_string_key, value)
          raise UriService::InvalidTemporaryTermUriError, "The supplied URI was not derived from the supplied (vocabulary_string_key+value) pair."
        end
      end
      
      unless uri =~ UriService::VALID_URI_REGEX
        raise UriService::InvalidUriError, "Invalid URI supplied during term creation: #{uri}"
      end
      
      #Ensure that vocabulary with vocabulary_string_key exists
      if self.find_vocabulary(vocabulary_string_key).nil?
        raise UriService::NonExistentVocabularyError, "There is no vocabulary with string key: " + vocabulary_string_key.to_s
      end
      
      # Stringify and validate keys for additional_fields
      additional_fields.stringify_keys!
      validate_additional_field_keys(additional_fields) # This method call raises an error if an invalid additional_field key is supplied
      
      @db.transaction do
        value_hash = Digest::SHA256.hexdigest(value)

        begin
          db_id = @db[UriService::TERMS].insert(
            type: type,
            uri: uri,
            uri_hash: Digest::SHA256.hexdigest(uri),
            value: value,
            value_hash: value_hash,
            authority: authority,
            vocabulary_string_key: vocabulary_string_key,
            additional_fields: JSON.generate(additional_fields)
          )
          send_term_to_solr(vocabulary_string_key, value, uri, authority, additional_fields, type, db_id)
        rescue Sequel::UniqueConstraintViolation
          
          # If the user is trying to create a new TEMPORARY term and we ran into a Sequel::UniqueConstraintViolation,
          # that means that the term already exists.  We will return that existing term, but also update the term with
          # any non-existent additional_fields supplied by the user and during this create operation, and a supplied
          # authority if the term did not already have an authority.
          if type == UriService::TermType::TEMPORARY
            temporary_term = self.find_term_by_uri(uri)
            
            opts = {}
            non_existent_additional_fields = additional_fields.keys - temporary_term.keys
            
            if non_existent_additional_fields.length > 0
              additional_fields_to_merge_in = additional_fields.select{|k, v| non_existent_additional_fields.include?(k)}
              opts[:additional_fields] = additional_fields_to_merge_in
            end
            
            if temporary_term['authority'].nil? && authority.length > 0 && authority != temporary_term['authority']
              opts[:authority] = authority
            end
            
            if opts.size > 0
              temporary_term = UriService.client.update_term(temporary_term['uri'], opts, true)
            end
            
            return temporary_term
          end
          
          raise UriService::ExistingUriError, "A term already exists with uri: " + uri + " (conflict found via uri_hash check)"
        end
        
        return generate_frozen_term_hash(vocabulary_string_key, value, uri, authority, additional_fields, type, db_id)
      end
    end
  end
  
end

class UriService::Error < StandardError;end
class UriService::CannotChangeTemporaryTermValue < UriService::Error;end
class UriService::CouldNotGenerateUriError < UriService::Error;end
class UriService::InvalidAdditionalFieldKeyError < UriService::Error;end
class UriService::InvalidOptsError < UriService::Error;end
class UriService::InvalidTemporaryTermUriError < UriService::Error;end
class UriService::InvalidTermTypeError < UriService::Error;end
class UriService::InvalidUriError < UriService::Error;end
class UriService::InvalidVocabularyStringKeyError < UriService::Error;end
class UriService::ExistingUriError < UriService::Error;end
class UriService::ExistingVocabularyStringKeyError < UriService::Error;end
class UriService::NonExistentUriError < UriService::Error;end
class UriService::NonExistentVocabularyError < UriService::Error;end
class UriService::UnsupportedObjectTypeError < UriService::Error;end
class UriService::UnsupportedSearchFieldError < UriService::Error;end