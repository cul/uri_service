#URI Service

A database-backed and Solr-cached lookup/creation service for URIs.  Works with or without Rails.

### Major Concepts:

**External Term (UriService::TermType::EXTERNAL)**

Used when caching a value/URI pair from an external controlled vocabulary within your UriService datastore.  Example: We want to add an entry for U.S. President Abraham Lincoln to our UriService datastore, so we'll create an external term that references his Library of Congress URI.

**Local Term (UriService::TermType::LOCAL)**

Used when defining locally-managed terms in the UriService datastore. Automatically creates a local URI for a new local term.  Example: We want to maintain a vocabulary for various departments within a university, and we want to create locally-managed URIs for these departments.

**Temporary Term (UriService::TermType::TEMPORARY)**

Used when you want to add a value to your UriService datastore, but have no authority information about the term and do not wish to create a local URI. Temporary term entries cannot store additional data fields, and no two temporary terms within the same vocabulary can have the same value. Basically, a termporary term is intended to identify an *exact string value* rather than identifiying an intellectual entity. Temporary terms should eventually be replaced by external or local terms later on when more information is known about the entity to which you are referring .  Example: We want to record information about the author of an old and mysterious letter by "John Smith."  We don't know which "John Smith," this refers to, so we'll create (or re-use) a temporary URI that's associated with the value "John Smith."  One day, when we figure out more about the letter and the author, we'll be able to update the record information and refer to an external term that has a globally-recognized URI, or we'll create a local URI if an external URI is unavailable.

### Usage:

**Install uri_service:**

```bash
gem install uri_service
```

**Initialize and use the main client instance:**

```ruby
UriService::init({
  'local_uri_base' => 'http://id.example.com/term/',
  'temporary_uri_base' => 'com:example:id:temporary:',
  'solr' => {
    'url' => 'http://localhost:8983/solr/uri_service_test',
    'pool_size' => 5,
    'pool_timeout' => 5000
  }
  'database' => {
    'adapter' => sqlite,
    'database' => db/test.sqlite3,
    'max_connections' => 5
    'pool_timeout' => 5000
  }
})

UriService.client.do_stuff(...)
```

**Or create your own separate instance:**

```ruby
client = UriService::Client.new({
  'local_uri_base' => 'http://id.example.com/term/',
  'temporary_uri_base' => 'com:example:id:temporary:',
  'solr' => {
    'url' => 'http://localhost:8983/solr/uri_service_test',
    'pool_size' => 5,
    'pool_timeout' => 5000
  }
  'database' => {
    'adapter' => sqlite,
    'database' => db/test.sqlite3,
    'max_connections' => 5
    'pool_timeout' => 5000
  }
})

client.do_stuff(...)
```

**Note: Each instance of UriService::Client creates a solr connection pool and a database connection pool, so it's better to share a single instance rather than create many separate instances.**

### In Rails:

When including the uri_service gem in Rails, create a file at **config/uri_service.yml** file that includes configurations for each environment.  These settings will be picked up automatically and passed to UriService::init() for the current environment.

Note that the database that you specify here does not have to be the same database that your other Rails models point to (in your Rails database.yml file).  If multiple apps share the same URI Service data, you may want to have a separate, shared database.

**uri_service.yml:**

```yaml
development:
  local_uri_base: 'http://id.example.com/term/'
  temporary_uri_base: 'com:example:id:temporary:'
  solr:
    url: 'http://localhost:8983/solr/uri_service_development'
    pool_size: 5
    pool_timeout: 5000
  database:
    adapter: sqlite
    database: db/uri_service_development.sqlite3
    max_connections: 5
    pool_timeout: 5000

test:
  local_uri_base: 'http://id.example.com/term/'
  temporary_uri_base: 'com:example:id:temporary:'
  solr:
    url: 'http://localhost:8983/solr/uri_service_test'
    pool_size: 5
    pool_timeout: 5000
  database:
    adapter: sqlite
    database: db/uri_service_test.sqlite3
    max_connections: 5
    pool_timeout: 5000

production:
  local_uri_base: 'http://id.example.com/term/'
  temporary_uri_base: 'com:example:id:temporary:'
  solr:
    url: 'http://localhost:9983/solr/uri_service_production'
    pool_size: 5
    pool_timeout: 5000
  database:
    adapter: mysql2
    database: dbname
    max_connections: 10
    pool_timeout: 5000
    timeout: 5000
    host: uri_service_prod.example.com
    port: 3306
    username: the_username
    password: the_password
```

### Using different database systems (sqlite, MySQL, PostgreSQL):

Parameters for the database config are passed directly to a new instance of a Sequel library connection, so any options offered by Sequel can be used here.  (Just be sure to set the right adapter).  See: http://sequel.jeremyevans.net/rdoc/files/doc/opening_databases_rdoc.html

### Creating Vocabularies and Terms:

Create a vocabulary:
```ruby
# Creates a vocabulary with string key 'names' and display label 'Names'

UriService.client.create_vocabulary('names', 'Names')
```

Listing vocabularies:
```ruby
limit = 10
start = 0
UriService.client.list_vocabularies(limit, start)
```

Create a term in a vocabulary:
```ruby
# Create an EXTERNAL term in the 'names' vocabulary, using an external URI
UriService.client.create_term(UriService::TermType::EXTERNAL, {vocabulary_string_key: 'names', value: 'Lincoln, Abraham, 1809-1865', uri: 'http://id.loc.gov/authorities/names/n79006779', additional_fields: {'is_awesome' => true, 'best_president' => true, 'hat_type' => 'Stove Pipe'}})

# Create a LOCAL term in the 'departments' vocabulary (note: A URI is not passed in because LOCAL terms generate their own URIs)
UriService.client.create_term(UriService::TermType::LOCAL, {vocabulary_string_key: 'departments', value: 'Chemistry', additional_fields: {'department_code' => 'CHEM'}})

# Create a TEMPORARY term in the 'departments' vocabulary (note: A URI is not passed in because TEMPORARY terms generate their own URIs, and additional_fields are not allowed)
UriService.client.create_term(UriService::TermType::TEMPORARY, {vocabulary_string_key: 'names', value: 'Smith, John'})
```

Searching by string query for a term in a vocabulary:
```ruby
UriService.client.find_terms_by_query('names', 'batman')
# =>
# [
#   {
#     'uri' => 'http://id.loc.gov/authorities/names/n91059657',
#     'value' => 'Batman, John, 1800-1839',
#     'vocabulary_string_key' => 'names',
#     'type' => 'external'
#   }
#   {
#     'uri' => 'http://id.loc.gov/authorities/names/n82259885',
#     'value' => 'Batman, Stephen, -1584',
#     'vocabulary_string_key' => 'names',
#     'type' => 'external'
#   },
# ]
```

Alternate way to find terms without a text query:
```ruby
UriService.client.find_terms_where(
  {
    'vocabulary_string_key' => 'names',
    'value' => 'Smith, John',
    'type' => UriService::TermType::EXTERNAL
  },
  11
)

# Above method call returns an array of up to 11 terms, or an empty array if no terms are found
```

Finding a single term by URI:
```ruby
UriService.client.find_term_by_uri('http://id.example.com/123')
# Returns a term hash or nil
```

Listing terms in a vocabulary:
```ruby
limit = 10
start = 0
UriService.client.list_terms('names', limit, start)
```

### Rake Tasks for Rails:

Setup required database tables:
```sh
bundle exec rake uri_service:db:setup
```

Also available outside of Rails as:

```ruby
UriService.client.create_required_tables
```

Reindex all database terms into Solr:
```sh
bundle exec rake uri_service:solr:reindex_all_terms # Reindex all terms in the database

bundle exec rake uri_service:solr:reindex_all_terms CLEAR=true # Clear solr index before reindexing all terms (to remove old terms)
```

Also available outside of Rails as:

```ruby
UriService.client.reindex_all_terms(false, false) # Reindex
UriService.client.reindex_all_terms(true, false) # Clear solr index and reindex
```

### Problems when sharing an sqlite database with Rails:
If you're using an sqlite database for your Rails application's standard ActiveRecord connection (which is probably not the case in production environments), you should avoid using the same sqlite database file for UriService due to database locking issues -- otherwise you're likely to encounter this error:

```
SQLite3::ReadOnlyException: attempt to write a readonly database
```
In most cases, you'll probably find it easier to keep the UriService tables in a separate database anyway.

### Running Integration Tests (for developers):

Integration tests are great and we should run them.  Here's how:

```sh
bundle exec rake uri_service:ci
```
