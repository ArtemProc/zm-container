# Base Image
FROM ubuntu:22.04

#ENV ZM_DB_HOST=mariadb
#ENV ZM_DB_NAME=zoneminder_db
#ENV ZM_DB_USER=zm_user
#ENV ZM_DB_PASS=q2w1e4r3

# this is just a default
ENV TZ=Europe/Amsterdam
ARG DEBIAN_FRONTEND=noninteractive

# install packages wit apt
RUN apt update \
    && apt-get upgrade --yes \
    && apt-get install --yes \
    software-properties-common \
    && add-apt-repository ppa:iconnor/zoneminder-1.36 --yes \
    && apt-get install --yes \
    zoneminder \
    && a2enconf zoneminder \
    && a2enmod rewrite cgi \
    && chmod 777 -R /var/run/mysqld/
    

# Setup Volumes
VOLUME /var/cache/zoneminder/events /var/cache/zoneminder/images /var/lib/mysql /var/log/zm

# Expose http port
EXPOSE 80

# Configure entrypoint
COPY ./entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
