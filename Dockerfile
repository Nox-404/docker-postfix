From ubuntu:trusty
MAINTAINER Elliott Ye

# Set noninteractive mode for apt-get
ENV DEBIAN_FRONTEND noninteractive

# Update
RUN apt-get update

# Start editing
# Install package here for cache
RUN apt-get -y install supervisor postfix sasl2-bin opendkim opendkim-tools mailutils dnsutils

ENV MAILDOMAIN example.com
ENV MAILSIGNING ""
ENV USERS mta@example.com:password mta2@example.com:password
ENV CERTNAME ""
ENV SMTP_RESTRICTIONS permit_sasl_authenticated,reject_unauth_destination

VOLUME /etc/postfix/certs
VOLUME /etc/opendkim/domainkeys

# Add files
COPY assets/install.sh /opt/install.sh

# Run
WORKDIR /opt
CMD /opt/install.sh && /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
