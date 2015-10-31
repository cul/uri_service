#URI Service

A database-backed and Solr-cached lookup/creation service for URIs.  Works with or without Rails.

### Usage:

**Install uri_service:**

```bash
gem install uri_service
```

**Initialize and use the main client instance:**

```ruby
UriService::init({
  'local_uri_base' => 'http://id.example.com/term/',
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
# Creates a term in the 'names' vocabulary, using the given value, uri and a couple of custom key-value pairs

UriService.client.create_term('names', 'Lincoln, Abraham, 1809-1865', 'http://id.loc.gov/authorities/names/n79006779', {'is_awesome' => true, 'best_president' => true, 'hat_type' => 'Stove Pipe'})
```

Create a LOCAL term in a vocabulary (when you don't have a URI for your term):
```ruby
# Creates a new LOCAL term in the 'names' vocabulary.  New URI is automatically generated.

UriService.client.create_local_term('names', 'Baby, Newborn', {'is_baby' => true})
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
#     'is_local' => false
#   }
#   {
#     'uri' => 'http://id.loc.gov/authorities/names/n82259885',
#     'value' => 'Batman, Stephen, -1584',
#     'vocabulary_string_key' => 'names',
#     'is_local' => false
#   },
# ]
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
