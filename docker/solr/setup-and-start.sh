#!/bin/bash

# Set up symlinks if they don't exist.  The conditional checks ensure that this only runs if
# the volume is re-created.
[ ! -L /var/solr/uri_service ] && ln -s /data/uri_service /var/solr/uri_service

precreate-core uri_service /template-cores/uri_service

# Start solr
solr-foreground
