#!/bin/bash

#judgement
if [[ -a /etc/supervisor/conf.d/supervisord.conf ]]; then
  exit 0
fi

#supervisor
cat > /etc/supervisor/conf.d/supervisord.conf <<EOF
[supervisord]
nodaemon=true

[program:postfix]
command=/opt/postfix.sh
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:rsyslog]
command=/usr/sbin/rsyslogd -n
EOF

############
#  postfix
############
cat >> /opt/postfix.sh <<EOF
#!/bin/bash
service postfix start
tail -f /var/log/mail.log
EOF
chmod +x /opt/postfix.sh
postconf -e myhostname=$MAILDOMAIN
postconf -F '*/*/chroot = n'
postconf -e always_add_missing_headers=yes

############
# SASL SUPPORT FOR CLIENTS
# The following options set parameters needed by Postfix to enable
# Cyrus-SASL support for authentication of mail clients.
############
# /etc/postfix/main.cf
postconf -e smtpd_sasl_auth_enable=yes
postconf -e broken_sasl_auth_clients=yes
postconf -e smtpd_recipient_restrictions=$SMTP_RESTRICTIONS
# smtpd.conf
cat >> /etc/postfix/sasl/smtpd.conf <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN CRAM-MD5 DIGEST-MD5 NTLM
EOF

# Add users into the sasldb2 database
for user in $USERS; do
  IFS=':' read email pass <<< "$user"
  if [[ -z "$pass" || -z "$email" ]]; then
    echo "Skip user: $user (mail or password empty)"
    continue
  fi
  echo $pass | saslpasswd2 -p -c -u $MAILDOMAIN $email
  echo "Add user: $email"
done
chown postfix.sasl /etc/sasldb2

############
# Enable TLS (if there is a certificate)
############
if [[ -z "$CERTNAME" && "$(find /etc/postfix/certs -name "*.crt" | wc -l | tr -d ' ')" != "0" ]]; then
  CERTNAME=$(find /etc/postfix/certs -name "*.crt" | head -1 | xargs basename -s .crt)
fi
if [[ -n "$CERTNAME" && -s /etc/postfix/certs/${CERTNAME}.crt && -s /etc/postfix/certs/${CERTNAME}.key ]]; then
  echo "Enforce TLS"
  # /etc/postfix/main.cf
  postconf -e smtpd_tls_cert_file=/etc/postfix/certs/${CERTNAME}.crt
  postconf -e smtpd_tls_key_file=/etc/postfix/certs/${CERTNAME}.key

  postconf -e smtpd_use_tls=yes
  postconf -e smtpd_tls_auth_only=yes
  postconf -e smtpd_tls_security_level=encrypt

  chmod 400 /etc/postfix/certs/*.* 2>&1 | grep -v "Read-only file system"
  # /etc/postfix/master.cf
  postconf -M submission/inet="submission   inet   n   -   n   -   -   smtpd"
  postconf -P "submission/inet/syslog_name=postfix/submission"
  postconf -P "submission/inet/smtpd_tls_security_level=encrypt"
  postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
  postconf -P "submission/inet/milter_macro_daemon_name=ORIGINATING"
  postconf -P "submission/inet/smtpd_recipient_restrictions=$SMTP_RESTRICTIONS"
else
  echo "Certificates for tls not found"
fi

#############
#  Opendkim ( if there is a key )
#############
if [[ "$(find /etc/opendkim/domainkeys -name "*.private" | wc -l | tr -d ' ')" != "0" && ! -f etc/opendkim/domainkeys/${CERTNAME}.private ]]; then
  CERTNAME=$(find /etc/opendkim/domainkeys -name "*.private" | head -1 | xargs basename -s .private)
fi
# No key found, exit
if [[ -z "$CERTNAME" || ! -s /etc/opendkim/domainkeys/${CERTNAME}.private ]]; then
  echo "Setup done"
  exit 0
fi

echo "Enable DKIM"
# Add opendkim process to supervisor
cat >> /etc/supervisor/conf.d/supervisord.conf <<EOF

[program:opendkim]
command=/usr/sbin/opendkim -fl
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF
# Add dkim milter
# /etc/postfix/main.cf
postconf -e milter_protocol=6
postconf -e milter_default_action=accept
postconf -e smtpd_milters=inet:localhost:12301
postconf -e non_smtpd_milters=inet:localhost:12301

# Configure opendkim
cat >> /etc/opendkim.conf <<EOF
AutoRestart             Yes
AutoRestartRate         10/1h
UMask                   002
Syslog                  yes
SyslogSuccess           Yes
LogResults              Yes
LogWhy                  Yes
Diagnostics             false
RequireSafeKeys         false

Canonicalization        relaxed/simple

ExternalIgnoreList      refile:/etc/opendkim/TrustedHosts
InternalHosts           refile:/etc/opendkim/TrustedHosts
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable

Mode                    sv
PidFile                 /var/run/opendkim/opendkim.pid
SignatureAlgorithm      rsa-sha256

SignHeaders             From,Sender,To,CC,Subject,Message-Id,Date
OversignHeaders         From,Sender,To,CC,Subject,Message-Id,Date

UserID                  opendkim:opendkim

Socket                  inet:12301@localhost
EOF

# Enable opendkim socket
cat >> /etc/default/opendkim <<EOF
SOCKET="inet:12301@localhost"
EOF

# Trust these domains
cat >> /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
192.168.0.1/24

*.${MAILSIGNING:-$MAILDOMAIN}
EOF

# Domain/Selector/Key lookup table
cat >> /etc/opendkim/KeyTable <<EOF
mail._domainkey.${MAILSIGNING:-$MAILDOMAIN} ${MAILSIGNING:-$MAILDOMAIN}:mail:/etc/opendkim/domainkeys/${CERTNAME}.private
EOF
# Which mail should be signed
cat >> /etc/opendkim/SigningTable <<EOF
*@${MAILSIGNING:-$MAILDOMAIN} mail._domainkey.${MAILSIGNING:-$MAILDOMAIN}
EOF
chown opendkim:opendkim $(find /etc/opendkim/domainkeys -name *.private) 2>&1 | grep -v "Read-only file system"
chmod 400 $(find /etc/opendkim/domainkeys -name *.private) 2>&1 | grep -v "Read-only file system"
echo "Setup done"
