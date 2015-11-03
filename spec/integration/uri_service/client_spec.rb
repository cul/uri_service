require 'spec_helper'
require 'yaml'
require 'uri_service/client'

describe UriService::Client, type: :integration do
  
  let(:uri_service_sqlite_config) { YAML.load(fixture('uri_service_test_config.yml'))['sqlite'] }
  let(:uri_service_fake_mysql2_config) { YAML.load(fixture('uri_service_test_config.yml'))['mysql2'] }
  
  # Clear all terms and vocabularies in database and solr before each example
  before :example do
    # Clear DB
    UriService.required_tables.each do |table|
      UriService.client.db[table].delete
    end
    # Clear Solr
    UriService.client.rsolr_pool.with do |rsolr|
      rsolr.delete_by_query('*:*')
      rsolr.commit
    end
  end

  describe "#test_connection" do
    
    it "can test a successful connection without raising any errors" do
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.not_to raise_error
    end
    
    it "raises an exception if no local_uri_base config is supplied" do
      uri_service_sqlite_config['local_uri_base'] = nil
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.to raise_error("Must supply opts['local_uri_base'] to initialize method.")
    end
    
    it "raises an exception if no temporary_uri_base config is supplied" do
      uri_service_sqlite_config['temporary_uri_base'] = nil
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.to raise_error("Must supply opts['temporary_uri_base'] to initialize method.")
    end
    
    it "raises an exception if no database config is supplied" do
      uri_service_sqlite_config['database'] = nil
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.to raise_error("Must supply opts['database'] to initialize method.")
    end
    
    it "raises an exception if no solr config is supplied" do
      uri_service_sqlite_config['solr'] = nil
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.to raise_error("Must supply opts['solr'] to initialize method.")
    end
    
    it "raises an exception when the database connection is unavailable" do
      expect{ UriService::Client.new(uri_service_fake_mysql2_config).test_connection }.to raise_error(Sequel::DatabaseConnectionError)
    end
    
    it "raises an exception when the database connection is unavailable" do
      uri_service_sqlite_config['solr']['url'] = 'http://localhost:10101/fake/solr'
      expect{ UriService::Client.new(uri_service_sqlite_config).test_connection }.to raise_error(Errno::ECONNREFUSED)
    end
    
  end
  
  describe "vocabulary create/update/delete/etc. methods" do
    describe "#create_vocabulary" do
      it "successfully creates a new vocabulary" do
        new_vocabulary_string_key = 'create_example'
        new_vocabulary_display_label = 'Create Example'
        expect(UriService.client.db[:vocabularies].where(string_key: new_vocabulary_string_key).count).to eq(0)
        UriService.client.create_vocabulary(new_vocabulary_string_key, new_vocabulary_display_label)
        expect(UriService.client.db[:vocabularies].where(string_key: new_vocabulary_string_key).count).to eq(1)
      end
      it "raises an exception when trying to create more than one vocabulary with the same string key" do
        new_vocabulary_string_key = 'another_create_example'
        new_vocabulary_display_label = 'Another Create Example'
        UriService.client.create_vocabulary(new_vocabulary_string_key, new_vocabulary_display_label) # First creation
        expect {
          UriService.client.create_vocabulary(new_vocabulary_string_key, new_vocabulary_display_label) # Duplicate creation
        }.to raise_error(UriService::ExistingVocabularyStringKeyError)
      end
      it "rejects invalid string keys" do
        ['all', 'invalid key', '_invalid', 'Invalid', '???invalid'].each_with_index do |invalid_key, index|
          expect {
            UriService.client.create_vocabulary(invalid_key, 'Some Label') # First creation
          }.to raise_error(UriService::InvalidVocabularyStringKeyError)
        end
      end
    end
    
    describe "#find_vocabulary" do
      it "returns nil when a vocabulary is not found" do
        expect(UriService.client.find_vocabulary('random12345nonexistent12345zzzz')).to be_nil
      end
      
      it "successfully finds a newly created vocabulary" do
        new_vocabulary_string_key = 'vocabulary_to_find'
        new_vocabulary_display_label = 'Vocabulary to Find'
        expect(UriService.client.find_vocabulary(new_vocabulary_string_key)).to be_nil
        UriService.client.create_vocabulary(new_vocabulary_string_key, new_vocabulary_display_label)
        found_vocabulary = UriService.client.find_vocabulary(new_vocabulary_string_key)
        expect(found_vocabulary[:string_key]).to eq(new_vocabulary_string_key)
        expect(found_vocabulary[:display_label]).to eq(new_vocabulary_display_label)
      end
    end
    
    describe "#delete_vocabulary" do
      it "successfully deletes a newly created vocabulary" do
        vocabulary_to_delete_string_key = 'vocabulary_to_delete'
        vocabulary_to_delete_display_label = 'Vocabulary to Delete'
        expect(UriService.client.find_vocabulary(vocabulary_to_delete_string_key)).to be_nil
        UriService.client.create_vocabulary(vocabulary_to_delete_string_key, vocabulary_to_delete_display_label)
        expect(UriService.client.find_vocabulary(vocabulary_to_delete_string_key)).not_to be_nil
        UriService.client.delete_vocabulary(vocabulary_to_delete_string_key)
        expect(UriService.client.find_vocabulary(vocabulary_to_delete_string_key)).to be_nil
      end
    end
    
    describe "#update_vocabulary" do
      it "successfully updates an existing vocabulary" do
        vocabulary_string_key = 'vocabulary_to_find'
        vocabulary_display_label = 'Vocabulary to Find'
        UriService.client.create_vocabulary(vocabulary_string_key, vocabulary_display_label)
        found_vocabulary = UriService.client.find_vocabulary(vocabulary_string_key)
        expect(found_vocabulary[:string_key]).to eq(vocabulary_string_key)
        expect(found_vocabulary[:display_label]).to eq(vocabulary_display_label)
        UriService.client.update_vocabulary(vocabulary_string_key, 'New Label')
        found_vocabulary = UriService.client.find_vocabulary(vocabulary_string_key)
        expect(found_vocabulary[:string_key]).to eq(vocabulary_string_key)
        expect(found_vocabulary[:display_label]).to eq('New Label')
      end
      it "raises an exception when trying to update a vocabulary that has not been created" do
        expect {
          UriService.client.update_vocabulary('vocabulary_does_not_exist', 'New Label')
        }.to raise_error(UriService::NonExistentVocabularyError)
      end
    end
    
    describe "#list_vocabularies" do
      it "returns a list of vocabularies, alphabetically sorted by string_key" do
        2.downto(0) do |i|
          UriService.client.create_vocabulary("vocab#{i}", "Vocabulary #{i}")
        end
        expect(UriService.client.list_vocabularies()).to eq([
          {'string_key' => 'vocab0', 'display_label' => 'Vocabulary 0'},
          {'string_key' => 'vocab1', 'display_label' => 'Vocabulary 1'},
          {'string_key' => 'vocab2', 'display_label' => 'Vocabulary 2'},
        ])
      end
      
      it "can page through results using the limit and start params, proving that the limit and start params work properly" do
        
        9.downto(0) do |i|
          UriService.client.create_vocabulary("vocab#{i}", "Vocabulary #{i}")
        end
        
        expect(UriService.client.list_vocabularies(4, 0)).to eq([
          {'string_key' => 'vocab0', 'display_label' => 'Vocabulary 0'},
          {'string_key' => 'vocab1', 'display_label' => 'Vocabulary 1'},
          {'string_key' => 'vocab2', 'display_label' => 'Vocabulary 2'},
          {'string_key' => 'vocab3', 'display_label' => 'Vocabulary 3'},
        ])
        expect(UriService.client.list_vocabularies(4, 4)).to eq([
          {'string_key' => 'vocab4', 'display_label' => 'Vocabulary 4'},
          {'string_key' => 'vocab5', 'display_label' => 'Vocabulary 5'},
          {'string_key' => 'vocab6', 'display_label' => 'Vocabulary 6'},
          {'string_key' => 'vocab7', 'display_label' => 'Vocabulary 7'},
        ])
        expect(UriService.client.list_vocabularies(4, 8)).to eq([
          {'string_key' => 'vocab8', 'display_label' => 'Vocabulary 8'},
          {'string_key' => 'vocab9', 'display_label' => 'Vocabulary 9'},
        ])
        
      end
    end
  end
  
  describe "term create/update/delete/etc. methods" do
    
    describe "#create_term_impl" do
      
      let (:vocabulary_string_key) { 'names' }
    
      before :example do
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
      end
      
      it "creates a term and returns a frozen term hash" do
        uri = 'http://id.library.columbia.edu/term/1234567'
        value = 'Cool Value'
        term = UriService.client.send(:create_term_impl, UriService::TermType::EXTERNAL, vocabulary_string_key, value, uri, {})
        expect(term.frozen?).to eq(true)
        expect(term).to eq({
          'vocabulary_string_key' => vocabulary_string_key,
          'uri' => uri,
          'value' => value,
          'type' => UriService::TermType::EXTERNAL,
        })
      end
      
      it "raises an error when a user attempts to create more than one EXTERNAL term with the same URI" do
        uri = 'http://id.example.gov/1234567'
        UriService.client.send(:create_term_impl, UriService::TermType::EXTERNAL, vocabulary_string_key, 'Val 1', uri, {})
        expect {
          UriService.client.send(:create_term_impl, UriService::TermType::EXTERNAL, vocabulary_string_key, 'Val 2', uri, {})
        }.to raise_error(UriService::ExistingUriError)
      end
      
      it "raises an error when a user attempts to create more than one LOCAL term with the same URI" do
        uri = 'http://id.library.columbia.edu/term/1234567'
        UriService.client.send(:create_term_impl, UriService::TermType::LOCAL, vocabulary_string_key, 'Val 1', uri, {})
        expect {
          UriService.client.send(:create_term_impl, UriService::TermType::LOCAL, vocabulary_string_key, 'Val 2', uri, {})
        }.to raise_error(UriService::ExistingUriError)
      end
      
      it "does NOT raise an error when a user attempts to create more than one TEMPORARY term with the same URI, but instead silently fails and returns the previously created first instance." do
        value = 'Temp Term'
        uri = UriService.client.generate_uri_for_temporary_term(vocabulary_string_key, value)
        term1 = UriService.client.send(:create_term_impl, UriService::TermType::TEMPORARY, vocabulary_string_key, value, uri, {})
        term2 = nil
        expect {
          term2 = UriService.client.send(:create_term_impl, UriService::TermType::TEMPORARY, vocabulary_string_key, value, uri, {})
        }.not_to raise_error
        expect(term1).to eq(term2)
        expect(UriService.client.list_terms(vocabulary_string_key, 2).length).to eq(1)
      end
      
      it "raises an error when the supplied uri was not derived from the supplied from the supplied vocabulary_string_key and value" do
        value = 'Some Term'
        uri = 'some:uri'
        expect {
          UriService.client.send(:create_term_impl, UriService::TermType::TEMPORARY, vocabulary_string_key, value, uri, {})
        }.to raise_error(UriService::InvalidTemporaryTermUriError)
      end
      
      it "rejects invalid URIs" do
        uri = 'not a uri'
        value = 'Cool Value'
        expect {
          UriService.client.send(:create_term_impl, UriService::TermType::EXTERNAL, vocabulary_string_key, value, uri, {})
        }.to raise_error(UriService::InvalidUriError)
      end
      it "rejects invalid additional_fields keys (which can only contain lower case letters, numbers and underscores, but cannot start with an underscore)" do
        ['invalid key', '_invalid', 'Invalid', '???invalid'].each_with_index do |invalid_key, index|
          expect {
            UriService.client.send(:create_term_impl, UriService::TermType::EXTERNAL, vocabulary_string_key, 'zzz', "http://id.loc.gov/something/cool", {invalid_key => 'cool value'})
          }.to raise_error(UriService::InvalidAdditionalFieldKeyError)
        end
      end
      it "raises an error when trying to create a term in a vocabulary that has not been created" do
        nonexistent_vocabulary_string_key = 'nonexistent'
        expect {
          UriService.client.send(:create_term_impl, UriService::TermType::EXTERNAL, nonexistent_vocabulary_string_key, 'zzz', "http://id.loc.gov/something/cool", {})
        }.to raise_error(UriService::NonExistentVocabularyError)
      end
      it "raises an error when supplying an additional field that is a reserved key" do
        expect {
          UriService.client.send(:create_term_impl, UriService::TermType::EXTERNAL, vocabulary_string_key, 'zzz', "http://id.loc.gov/something/cool", {'value' => '12345'})
        }.to raise_error(UriService::InvalidAdditionalFieldKeyError)
      end
      it "raises an error when supplying additional_fields to a TEMPORARY term" do
        value = 'Some Term'
        uri = UriService.client.generate_uri_for_temporary_term(vocabulary_string_key, value)
        expect {
          UriService.client.send(:create_term_impl, UriService::TermType::TEMPORARY, vocabulary_string_key, value, uri, {some_key: 'some value'})
        }.to raise_error(UriService::InvalidOptsError)
      end
      it "creates a uri entry in both the database and solr" do
        uri = 'http://id.library.columbia.edu/term/1234567'
        
        # Expect 0 results in solr and 0 results in db before term creation
        expect(UriService.client.db[UriService::TERMS].where(uri: uri).count).to eq(0)
        UriService.client.rsolr_pool.with do |rsolr|
          response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
          expect(response['response']['numFound']).to eq(0)
        end
        
        # Create term
        UriService.client.send(:create_term_impl, UriService::TermType::EXTERNAL, vocabulary_string_key, 'zzz', uri, {})
        
        # Expect 1 result in solr and 1 result in db after term creation
        expect(UriService.client.db[UriService::TERMS].where(uri: uri).count).to eq(1)
        
        UriService.client.rsolr_pool.with do |rsolr|
          response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
          expect(response['response']['numFound']).to eq(1)
        end
      end
    end
    
    describe "#create_term" do
      
      let (:vocabulary_string_key) { 'names' }
    
      before :example do
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
      end
      
      it "creates an EXTERNAL term and returns a frozen term hash" do
        uri = 'http://id.library.columbia.edu/term/1234567'
        
        term = UriService.client.create_term(
          UriService::TermType::EXTERNAL,
          {
            vocabulary_string_key: vocabulary_string_key,
            value: 'Value',
            uri: uri,
            additional_fields: {custom_field: 'custom value'}
          }
        )
        expect(term.frozen?).to eq(true)
        expect(term).to eq({
          'type' => UriService::TermType::EXTERNAL,
          'vocabulary_string_key' => vocabulary_string_key,
          'uri' => uri,
          'value' => 'Value',
          'custom_field' => 'custom value',
        })
      end
      
      it "creates a LOCAL term that starts with the UriService::Client#local_uri_base value and returns a frozen term hash" do
        term = UriService.client.create_term(
          UriService::TermType::LOCAL,
          {
            vocabulary_string_key: vocabulary_string_key,
            value: 'Value',
            additional_fields: {custom_field: 'custom value'}
          }
        )
        expect(term.frozen?).to eq(true)
        expect(term).to eq({
          'type' => UriService::TermType::LOCAL,
          'vocabulary_string_key' => vocabulary_string_key,
          'uri' => term['uri'],
          'value' => 'Value',
          'custom_field' => 'custom value',
        })
        expect(term['uri'].start_with?(UriService.client.local_uri_base)).to eq(true)
      end
      
      it "creates an TEMPORARY term that starts with the UriService::Client#temporary_uri_base value and returns a frozen term hash" do
        term = UriService.client.create_term(
          UriService::TermType::TEMPORARY,
          {
            vocabulary_string_key: vocabulary_string_key,
            value: 'Value'
          }
        )
        expect(term.frozen?).to eq(true)
        expect(term).to eq({
          'type' => UriService::TermType::TEMPORARY,
          'vocabulary_string_key' => vocabulary_string_key,
          'uri' => term['uri'],
          'value' => 'Value'
        })
        expect(term['uri'].start_with?(UriService.client.temporary_uri_base)).to eq(true)
      end
      
      it "raises an error if a user does NOT supply a uri for an EXTERNAL term" do
        expect {
          UriService.client.create_term(
            UriService::TermType::EXTERNAL,
            {
              vocabulary_string_key: vocabulary_string_key,
              value: 'Value'
            }
          )
        }.to raise_error(UriService::InvalidOptsError)
      end
      
      it "raises an error if a user supplies a uri for an INTERNAL or TEMPORARY term (because a uri is supposed to be generated by the code rather than the user) " do
        expect {
          UriService.client.create_term(
            UriService::TermType::LOCAL,
            {
              vocabulary_string_key: vocabulary_string_key,
              value: 'Value',
              uri: 'http://something.example.com/123'
            }
          )
        }.to raise_error(UriService::InvalidOptsError)
        
        expect {
          UriService.client.create_term(
            UriService::TermType::TEMPORARY,
            {
              vocabulary_string_key: vocabulary_string_key,
              value: 'Value',
              uri: 'some:uri'
            }
          )
        }.to raise_error(UriService::InvalidOptsError)
      end
    end
    
    describe "#find_term_by_uri" do
      
      let (:vocabulary_string_key) { 'names' }
    
      before :example do
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
      end
      
      it "returns a result for an existing term" do
        uri = 'http://id.library.columbia.edu/term/123'
        value = 'My value'
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: value, uri: uri, additional_fields: {'custom_field' => 'custom value'}})
        
        expect(UriService.client.find_term_by_uri(uri)).to eq(
          {
            'type' => UriService::TermType::EXTERNAL,
            'uri' => uri,
            'value' => value,
            'vocabulary_string_key' => vocabulary_string_key,
            'custom_field' => 'custom value'
          }
        )
      end
      it "returns nil when a term isn't found for the given uri" do
        uri = 'http://id.library.columbia.edu/term/123'
        value = 'My value'
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: value, uri: uri, additional_fields: {'custom_field' => 'custom value'}})
        
        expect(UriService.client.find_term_by_uri('https://id.library.columbia.edu/zzzzz')).to eq(nil)
      end
    end
    
    describe "#find_terms_where" do

      let(:vocabulary_string_key) { 'names' }
      let(:uri) { 'http://id.library.columbia.edu/term/1234567' }
      let(:value) { 'What a great value' }
      let(:type) { UriService::TermType::EXTERNAL }
      let(:additional_fields) { {'custom_field' => 'custom value'} }

      before :example do
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        UriService.client.create_term(type, {vocabulary_string_key: vocabulary_string_key, value: value, uri: uri, additional_fields: additional_fields})
      end

      it "returns nil when no results are found" do
        expect(UriService.client.find_terms_where(uri: 'http://fake.url.here/really/does/not/exist')).to eq([])
      end
      
      it "can find a term by uri" do
        expect(UriService.client.find_terms_where(uri: uri)).to eq([
          {
          'uri' => uri,
          'value' => value,
          'vocabulary_string_key' => vocabulary_string_key,
          'type' => type,
          'custom_field' => 'custom value'
          }
        ])
      end
      
      it "can find a term by type" do
        expect(UriService.client.find_terms_where(type: UriService::TermType::EXTERNAL)).to eq([
          {
            'uri' => uri,
            'value' => value,
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => type,
            'custom_field' => 'custom value'
          }
        ])
      end
      
      it "can find a term by value" do
        expect(UriService.client.find_terms_where(value: value)).to eq([
          {
            'uri' => uri,
            'value' => value,
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL,
            'custom_field' => 'custom value'
          }
        ])
      end
      
      it "can find a term by value" do
        expect(UriService.client.find_terms_where(vocabulary_string_key: vocabulary_string_key)).to eq([
          {
            'uri' => uri,
            'value' => value,
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL,
            'custom_field' => 'custom value'
          }
        ])
      end
      
      it "raises an exception when an invalid find_by condition is supplied" do
        expect {
            UriService.client.find_terms_where(invalid_field: 'zzz')
          }.to raise_error(UriService::UnsupportedSearchFieldError)
      end
      
    end
    
    describe "#create_term_solr_doc" do
      it "converts as expected" do
        uri = 'http://id.library.columbia.edu/term/1234567'
        value = 'What a great value'
        type = UriService::TermType::EXTERNAL
        vocabulary_string_key = 'some_vocabulary'
        additional_fields = {
          'field1' => 'string value',
          'field2' => 1,
          'field3' => true,
          'field4' => ['val1', 'val2'],
          'field5' => [1, 2, 3, 4, 5]
        }
        
        expected_solr_doc = {
          'uri' => 'http://id.library.columbia.edu/term/1234567',
          'value' => 'What a great value',
          'type' => type,
          'vocabulary_string_key' => 'some_vocabulary',
          'additional_fields' => '{"field1":"string value","field2":1,"field3":true,"field4":["val1","val2"],"field5":[1,2,3,4,5]}'
        }
        
        expect(UriService.client.create_term_solr_doc(
          vocabulary_string_key, value, uri, additional_fields, type
        )).to eq(expected_solr_doc)
      end
    end
    
    describe "#send_term_to_solr" do
      it "correctly creates/updates a document in solr" do
        vocabulary_string_key = 'names'
        value = 'Grrrrreat name!'
        uri = 'http://id.loc.gov/123'
        additional_fields = {'field1' => 1, 'field2' => ['aaa', 'bbb', 'ccc']}
        type = UriService::TermType::EXTERNAL
        
        expected1 = {
          'uri' => uri,
          'value' => value,
          'vocabulary_string_key' => vocabulary_string_key,
          'type' => type,
          "additional_fields" => '{"field1":1,"field2":["aaa","bbb","ccc"]}',
        }
        
        expected2 = {
          'uri' => uri,
          'value' => 'Even grrrreater value!',
          'vocabulary_string_key' => vocabulary_string_key,
          'type' => type,
          "additional_fields" => '{"field1":1,"field2":["aaa","bbb","ccc"]}',
        }
        
        UriService.client.send_term_to_solr(vocabulary_string_key, value, uri, additional_fields, type)
        UriService.client.rsolr_pool.with do |rsolr|
          response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
          doc = response['response']['docs'][0]
          expect(doc.except('score', 'timestamp', '_version')).to eq(expected1)
        end
        UriService.client.send_term_to_solr(vocabulary_string_key, 'Even grrrreater value!', uri, additional_fields, type)
        UriService.client.rsolr_pool.with do |rsolr|
          response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
          doc = response['response']['docs'][0]
          expect(doc.except('score', 'timestamp', '_version')).to eq(expected2)
        end
      end
    end
    
    describe "#list_terms" do
      it "returns a list of alphabetically terms" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Val 1', uri: 'http://id.loc.gov/fake/term1', additional_fields: {}})
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Val 2', uri: 'http://id.loc.gov/fake/term2', additional_fields: {}})
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Val 3', uri: 'http://id.loc.gov/fake/term3', additional_fields: {}})
        
        expected_search_results = [
          {'uri' => 'http://id.loc.gov/fake/term1', 'value' => 'Val 1', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/term2', 'value' => 'Val 2', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/term3', 'value' => 'Val 3', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL}
        ]
        
        expect(UriService.client.list_terms(vocabulary_string_key)).to eq(expected_search_results)
      end
      
      it "can page through results using the limit and start params, proving that the limit and start params work properly" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        10.times do |i|
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: "Name #{i}", uri: "http://id.loc.gov/fake/#{i}"})
        end
        
        expect(UriService.client.list_terms(vocabulary_string_key, 4, 0)).to eq([
          {'uri' => 'http://id.loc.gov/fake/0', 'value' => 'Name 0', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/1', 'value' => 'Name 1', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/2', 'value' => 'Name 2', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/3', 'value' => 'Name 3', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
        ])
        expect(UriService.client.list_terms(vocabulary_string_key, 4, 4)).to eq([
          {'uri' => 'http://id.loc.gov/fake/4', 'value' => 'Name 4', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/5', 'value' => 'Name 5', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/6', 'value' => 'Name 6', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/7', 'value' => 'Name 7', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
        ])
        expect(UriService.client.list_terms(vocabulary_string_key, 4, 8)).to eq([
          {'uri' => 'http://id.loc.gov/fake/8', 'value' => 'Name 8', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/9', 'value' => 'Name 9', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
        ])
        
      end
    end
    
    describe "#find_terms_by_query" do
      
      it "delegates to #list_terms and returns a list of alphabetically terms when the supplied query is blank" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        3.times do |i|
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: "Val #{i}", uri: "http://id.loc.gov/fake/term#{i}"})
        end
        
        expected_search_results = [
          {'uri' => 'http://id.loc.gov/fake/term0', 'value' => 'Val 0', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/term1', 'value' => 'Val 1', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/term2', 'value' => 'Val 2', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL}
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, '')).to eq(expected_search_results)
      end
      
      describe "does whole term match searches only for queries that are < 3 characters long" do
        it "works for 2 character queries, and is case insensitive" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          value = 'Me'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: value, uri: uri})
          
          expected_search_results = [{
            'uri' => uri,
            'value' => value,
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL
          }]
          
          expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'me')).to eq(expected_search_results)
          expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'zz')).to eq([])
        end
        
        it "works for 1 character queries, and is case insensitive" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          value = 'I'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: value, uri: uri})
          
          expected_search_results = [{
            'uri' => uri,
            'value' => value,
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL
          }]
          
          expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'i')).to eq(expected_search_results)
          expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'z')).to eq([])
        end
      end
      
      it "can find a newly created value when various partial and complete queries are given (partial must be >= 3 chars)" do
        vocabulary_string_key = 'names'
        uri = 'http://id.library.columbia.edu/term/1234567'
        value = 'What a great value'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: value, uri: uri})
        
        expected_search_results = [{
          'uri' => uri,
          'value' => value,
          'vocabulary_string_key' => vocabulary_string_key,
          'type' => UriService::TermType::EXTERNAL
        }]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'z')).to eq([]) # Letter not present in term returns no results
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'W')).to eq([]) # < 3 char string returns no results
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Wh')).to eq([]) # < 3 char string returns no results
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Wha')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What ')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a ')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a g')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a gr')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a gre')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a grea')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great ')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great v')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great va')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great val')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great valu')).to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'What a great value')).to eq(expected_search_results)
      end
      
      it "can do exact matching when a complete URI is given as a query, but does not match on an incomplete uri (with the last character chopped off)" do
        vocabulary_string_key = 'names'
        uri = 'http://id.library.columbia.edu/term/1234567'
        value = 'What a great value'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: value, uri: uri})
        
        expected_search_results = [{
          'uri' => uri,
          'value' => value,
          'vocabulary_string_key' => vocabulary_string_key,
          'type' => UriService::TermType::EXTERNAL
        }]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, uri[0...(uri.length-1)])).not_to eq(expected_search_results)
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, uri)).to eq(expected_search_results)
      end
      
      it "sorts exact matches first" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Cat', uri: 'http://id.loc.gov/fake/111'})
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Catastrophe', uri: 'http://id.loc.gov/fake/222'})
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Catastrophic', uri: 'http://id.loc.gov/fake/333'})
        
        expected_search_results = [
          { 'uri' => 'http://id.loc.gov/fake/111', 'value' => 'Cat', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL },
          { 'uri' => 'http://id.loc.gov/fake/222', 'value' => 'Catastrophe', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL },
          { 'uri' => 'http://id.loc.gov/fake/333', 'value' => 'Catastrophic', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL },
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Cat')).to eq(expected_search_results)
      end
      
      it "sorts full word matches first when present, even if there are other words in the term and it would otherwise sort later alphabetically" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'A Catastrophe', uri: 'http://id.loc.gov/fake/111'})
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Not Catastrophic', uri: 'http://id.loc.gov/fake/222'})
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'The Cat', uri: 'http://id.loc.gov/fake/333'})
        
        expected_search_results = [
          { 'uri' => 'http://id.loc.gov/fake/333', 'value' => 'The Cat', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL },
          { 'uri' => 'http://id.loc.gov/fake/111', 'value' => 'A Catastrophe', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL },
          { 'uri' => 'http://id.loc.gov/fake/222', 'value' => 'Not Catastrophic', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL },
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Cat')).to eq(expected_search_results)
      end
      
      it "sorts equally relevant results alphabetically" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Steve Jobs', uri: 'http://id.loc.gov/fake/222'})
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Steve Kobs', uri: 'http://id.loc.gov/fake/111'})
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Steve Lobs', uri: 'http://id.loc.gov/fake/333'})
        
        expected_search_results = [
          {
            'uri' => 'http://id.loc.gov/fake/222',
            'value' => 'Steve Jobs',
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL
          },
          {
            'uri' => 'http://id.loc.gov/fake/111',
            'value' => 'Steve Kobs',
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL
          },
          {
            'uri' => 'http://id.loc.gov/fake/333',
            'value' => 'Steve Lobs',
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL
          }
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Steve')).to eq(expected_search_results)
      end
      
      it "returns results for mid-word partial word queries" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Supermanners', uri: 'http://id.loc.gov/fake/111'})
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Batmanners', uri: 'http://id.loc.gov/fake/222'})
        
        expected_search_results = [
          {
            'uri' => 'http://id.loc.gov/fake/222',
            'value' => 'Batmanners',
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL
          },
          {
            'uri' => 'http://id.loc.gov/fake/111',
            'value' => 'Supermanners',
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL
          }
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'man')).to eq(expected_search_results)
      end
      
      it "doesn't return results that do not include the query" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Supermanners', uri: 'http://id.loc.gov/fake/111'})
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Batmanners', uri: 'http://id.loc.gov/fake/222'})
        
        expected_search_results = [
          {
            'uri' => 'http://id.loc.gov/fake/222',
            'value' => 'Batmanners',
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL
          }
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'bat')).to eq(expected_search_results)
      end
      
      it "performs a case insensitive search" do
        vocabulary_string_key = 'names'
        value = 'Batmanners'
        uri = 'http://id.loc.gov/fake/222'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: value, uri: uri})
        
        expected_search_results = [
          {
            'uri' => uri,
            'value' => value,
            'vocabulary_string_key' => vocabulary_string_key,
            'type' => UriService::TermType::EXTERNAL
          }
        ]
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'bAtMaNnErS')).to eq(expected_search_results)
      end
      
      it "can page through results using the limit and start params, proving that the limit and start params work properly" do
        vocabulary_string_key = 'names'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        10.times do |i|
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: "Name #{i}", uri: "http://id.loc.gov/fake/#{i}"})
        end
        
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Name', 4, 0)).to eq([
          {'uri' => 'http://id.loc.gov/fake/0', 'value' => 'Name 0', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/1', 'value' => 'Name 1', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/2', 'value' => 'Name 2', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/3', 'value' => 'Name 3', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
        ])
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Name', 4, 4)).to eq([
          {'uri' => 'http://id.loc.gov/fake/4', 'value' => 'Name 4', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/5', 'value' => 'Name 5', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/6', 'value' => 'Name 6', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/7', 'value' => 'Name 7', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
        ])
        expect(UriService.client.find_terms_by_query(vocabulary_string_key, 'Name', 4, 8)).to eq([
          {'uri' => 'http://id.loc.gov/fake/8', 'value' => 'Name 8', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
          {'uri' => 'http://id.loc.gov/fake/9', 'value' => 'Name 9', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
        ])
        
      end
      
    end
    
    describe "#delete_term" do
      it "can delete a term" do
        vocabulary_string_key = 'names'
        uri = 'http://id.library.columbia.edu/term/1234567'
        value = 'What a great value'
        UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
        UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: value, uri: uri})
        expect(UriService.client.find_term_by_uri(uri)).not_to eq(nil)
        UriService.client.delete_term(uri)
        expect(UriService.client.find_term_by_uri(uri)).to eq(nil)
      end
    end
    
    context "term update methods" do
      describe "#update_term" do
        it "can update the value and additional_fields for an existing term" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Original Value', uri: uri})
          expect(UriService.client.find_term_by_uri(uri)['value']).to eq('Original Value')
          UriService.client.update_term(uri, {value: 'New Value', additional_fields: {'new_field' => 'new field value'}})
          term = UriService.client.find_term_by_uri(uri)
          expect(term['value']).to eq('New Value')
          expect(term['new_field']).to eq('new field value')
        end
        it "returns a frozen term hash" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Original Value', uri: uri})
          term = UriService.client.update_term(uri, {value: 'New Value', additional_fields: {'new_field' => 'new field value'}})
          expect(term.frozen?).to eq(true)
          expect(term).to eq({
            'vocabulary_string_key' => vocabulary_string_key,
            'uri' => uri,
            'value' => 'New Value',
            'type' => UriService::TermType::EXTERNAL,
            'new_field' => 'new field value'
          })
        end
        it "properly updates both the database and solr, hashing the term uri and value" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'My term', uri: uri})
          expect(UriService.client.db[UriService::TERMS].where(uri: uri).count).to eq(1)
          UriService.client.rsolr_pool.with do |rsolr|
            response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
            expect(response['response']['numFound']).to eq(1)
          end
          
          new_value = 'updated value'
          new_additional_fields = {'updated' => true, 'cool' => 'very'}
          UriService.client.update_term(uri, {value: new_value, additional_fields: new_additional_fields}, false)
          
          db_row = UriService.client.db[UriService::TERMS].where(uri: uri).first
          doc = nil
          UriService.client.rsolr_pool.with do |rsolr|
            response = rsolr.get('select', params: { :q => '*:*', :fq => 'uri:' + RSolr.solr_escape(uri) })
            doc = response['response']['docs'].first
          end
          
          expect(db_row.except(:id)).to eq({
            :vocabulary_string_key => 'names',
            :value => new_value,
            :value_hash => '9c3868c849c38d8c8367cb29796d7d7d3378ef79a43b5e41b55bfcd15cf87f81',
            :uri => "http://id.library.columbia.edu/term/1234567",
            :uri_hash => "7dbe84657ed648d1748cb03d862cd4a45e590037bc4c2fcdbd04062ef4be226f",
            :type => UriService::TermType::EXTERNAL,
            :additional_fields => JSON.generate(new_additional_fields)
          })
          expect(doc.except('timestamp', '_version_', 'score', 'updated_bsi')).to eq({
            "vocabulary_string_key" => "names",
            "value" => "updated value",
            "uri" => "http://id.library.columbia.edu/term/1234567",
            "type" => UriService::TermType::EXTERNAL,
            "additional_fields" => '{"updated":true,"cool":"very"}',
          })
        end
        it "raises an exception when trying to update a term that does not exist" do
          expect {
            UriService.client.update_term('http://this.does.not.exist/really/does/not', {value: 'New Value'})
          }.to raise_error(UriService::NonExistentUriError)
        end
        it "rejects invalid additional_fields keys (which can only contain lower case letters, numbers and underscores, but cannot start with an underscore)" do
          vocabulary_string_key = 'names'
          uri = "http://id.library.columbia.edu/term/111"
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Value', uri: uri, additional_fields: {'valid_key' => 'cool value'}})
          ['invalid key', '_invalid', 'Invalid', '???invalid'].each_with_index do |invalid_key, index|
            expect {
              UriService.client.update_term(uri, {additional_fields: {invalid_key => 'some value'}})
            }.to raise_error(UriService::InvalidAdditionalFieldKeyError)
          end
        end
        it "raises an exception when trying to update a term that does not exist" do
          expect {
            UriService.client.update_term('http://this.does.not.exist/really/does/not', {additional_fields: {'something' => 'here'}})
          }.to raise_error(UriService::NonExistentUriError)
        end
        it "merges supplied additional fields for a regular term when merge param is not supplied (because merge defaults to true)" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Original Value', uri: uri, additional_fields: {'some_key' => 'some val'}})
          expect(UriService.client.find_term_by_uri(uri)['some_key']).to eq('some val')
          UriService.client.update_term(uri, {additional_fields: {'another_key' => 'another val'}})
          term = UriService.client.find_term_by_uri(uri)
          expect(term['some_key']).to eq('some val')
          expect(term['another_key']).to eq('another val')
        end
        it "can replace all of the additional fields for a regular term when merge param equals false" do
          vocabulary_string_key = 'names'
          uri = 'http://id.library.columbia.edu/term/1234567'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Original Value', uri: uri, additional_fields: {'some_key' => 'some val'}})
          expect(UriService.client.find_term_by_uri(uri)['some_key']).to eq('some val')
          UriService.client.update_term(uri, {additional_fields: {'another_key' => 'another val'}}, false)
          term = UriService.client.find_term_by_uri(uri)
          expect(term['some_key']).to be_nil
          expect(term['another_key']).to eq('another val')
        end
        it "will raise an error a user attempts to update a TEMPORARY term (because TEMPORARY terms cannot be updated)" do
          vocabulary_string_key = 'names'
          UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
          term = UriService.client.create_term(UriService::TermType::TEMPORARY, {vocabulary_string_key: vocabulary_string_key, value: 'The Value'})
          expect {
            UriService.client.update_term(term['uri'], {value: 'New Value'})
          }.to raise_error(UriService::CannotChangeTemporaryTerm)
        end
      end
    end
  end
  
  describe "#generate_frozen_term_hash" do
    it "works as expected" do
      vocabulary_string_key = 'names'
      uri = 'http://id.loc.gov/123'
      value = 'Some value'
      type = UriService::TermType::EXTERNAL
      
      additional_fields = {
        'field1' => 'one',
        'field2' => 2,
        'field3' => true,
        'field4' => ['one', 'two', 'three'],
        'field5' => [1, 2, 3]
      }
      
      term = UriService.client.generate_frozen_term_hash(vocabulary_string_key, value, uri, additional_fields, type)
      expect(term.frozen?).to eq(true)
      expect(term).to eq({
        'vocabulary_string_key' => vocabulary_string_key,
        'uri' => uri,
        'value' => value,
        'type' => UriService::TermType::EXTERNAL,
        'field1' => 'one',
        'field2' => 2,
        'field3' => true,
        'field4' => ['one', 'two', 'three'],
        'field5' => [1, 2, 3]
      })
      
      # And when we attempt to modify the frozen hash, a RuntimeError error is raised
      expect{ term['value'] = 'new value' }.to raise_error(RuntimeError)
    end
  end
  
  describe "#term_solr_doc_to_frozen_term_hash" do
    it "works as expected" do
      
      vocabulary_string_key = 'names'
      uri = 'http://id.loc.gov/123'
      value = 'Some value'
      type = UriService::TermType::EXTERNAL
      
      doc = {
        'vocabulary_string_key' => vocabulary_string_key,
        'uri' => uri,
        'value' => value,
        'type' => type,
        'additional_fields' => '{"field1":"one","field2":2,"field3":true,"field4":["one","two","three"],"field5":[1,2,3]}'
      }
      
      term = UriService.client.term_solr_doc_to_frozen_term_hash(doc)
      expect(term.frozen?).to eq(true)
      expect(term).to eq({
        'vocabulary_string_key' => vocabulary_string_key,
        'uri' => uri,
        'value' => value,
        'type' => type,
        'field1' => 'one',
        'field2' => 2,
        'field3' => true,
        'field4' => ['one', 'two', 'three'],
        'field5' => [1, 2, 3]
      })
    end
  end
  
  describe "#reindex_all_terms" do
    it "can reindexing existing terms" do
      vocabulary_string_key = 'names'
      UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
      
      UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Bob', uri: 'http://id.loc.gov/fake/111'})
      UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Prometheus', uri: 'http://id.loc.gov/fake/222'})
      
      expected_search_results = [
        {'uri' => 'http://id.loc.gov/fake/111', 'value' => 'Bob', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
        {'uri' => 'http://id.loc.gov/fake/222', 'value' => 'Prometheus', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
      ]
      
      expect(UriService.client.list_terms(vocabulary_string_key)).to eq(expected_search_results)
      
      # Clear Solr index
      UriService.client.rsolr_pool.with do |rsolr|
        rsolr.delete_by_query('*:*')
        rsolr.commit
      end
      
      expect(UriService.client.list_terms(vocabulary_string_key)).to eq([])
      
      # Reindex
      UriService.client.reindex_all_terms()
      expect(UriService.client.list_terms(vocabulary_string_key)).to eq(expected_search_results)
    end
    
    it "clears the index before reindexing if the clear param is given a value of true" do
      vocabulary_string_key = 'names'
      UriService.client.create_vocabulary(vocabulary_string_key, 'Names')
      
      UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Bob', uri: 'http://id.loc.gov/fake/111'})
      UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: vocabulary_string_key, value: 'Prometheus', uri: 'http://id.loc.gov/fake/222'})
      
      expected_search_results = [
        {'uri' => 'http://id.loc.gov/fake/111', 'value' => 'Bob', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
        {'uri' => 'http://id.loc.gov/fake/222', 'value' => 'Prometheus', 'vocabulary_string_key' => vocabulary_string_key, 'type' => UriService::TermType::EXTERNAL},
      ]
      
      expect(UriService.client.list_terms(vocabulary_string_key)).to eq(expected_search_results)
      
      # Delete all terms in the database, but not in solr
      UriService.client.db[UriService::TERMS].delete
      
      # We expect to still see the terms in solr before the reindex
      expect(UriService.client.list_terms(vocabulary_string_key)).to eq(expected_search_results)
      
      # We expect to see zero terms after the reindex (with clear=true)
      clear = true
      UriService.client.reindex_all_terms(clear)
      expect(UriService.client.list_terms(vocabulary_string_key)).to eq([])
    end
  end
  
  #describe "::get_solr_suffix_for_object" do
  #  it "creates the expected suffixes for supported object types" do
  #    expect(UriService::Client::get_solr_suffix_for_object( 'string value'   )).to eq('_ssi')
  #    expect(UriService::Client::get_solr_suffix_for_object( 1                )).to eq('_isi')
  #    expect(UriService::Client::get_solr_suffix_for_object( true             )).to eq('_bsi')
  #    expect(UriService::Client::get_solr_suffix_for_object( ['val1', 'val2'] )).to eq('_ssim')
  #    expect(UriService::Client::get_solr_suffix_for_object( [1, 2, 3, 4, 5]  )).to eq('_isim')
  #  end
  #
  #  it "raises an exception for unsupported object types" do
  #    expect{ UriService::Client::get_solr_suffix_for_object(Struct.new(:something)) }.to raise_error(UriService::UnsupportedObjectTypeError)
  #  end
  #end

end
