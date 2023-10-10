FROM solr:8.11.2

WORKDIR /data

COPY ./setup-and-start.sh .

COPY --chown=solr:solr './solr_cores/uri-service-solr-8' /template-cores/uri_service
RUN echo 'name=uri_service' > /template-cores/uri_service/core.properties

CMD /bin/bash ./setup-and-start.sh
