# ``TelepathTLS``

TLS for `ssl://` links, reproducing Synapse's deliberately non-standard rules.

## Overview

Synapse services routinely run on dynamic IPs, so its client turns off hostname
verification and does its own checking. Reproducing that exactly is not optional:
a conventional TLS client cannot connect to a real deployment.

- Hostname verification is off in both modes.
- A pinned `certhash` takes precedence. It disables chain trust entirely, compares
  the SHA-256 of the peer's DER certificate, and then does **not** consult the
  common name at all — mirroring `if certhash: ... elif hostname:`.
- Otherwise the CA chain is verified and the certificate's subject **common name**,
  not its SAN, is compared to the hostname exactly: no wildcards, no case folding,
  because Synapse compares with `!=`.
- A user supplied without a password authenticates by a client certificate named
  `{user}@{hostname}` from the certificate directory.

## Topics

### Policy

- ``TLSPolicy``
- ``TelepathTLS``
- ``TLSHandshakeHandler``
- ``TLSVerificationFailure``

### Certificates

- ``CertificateDirectory``
- ``TLSError``
