# pki/

`nggocnn-homelab-ca.crt` is the **public** certificate of the homelab's internal
CA. It is not secret — it is the file you install on devices so they trust
`*.nggocnn.io`.

The CA **private key** and the wildcard certificate live in
`secrets/pki.sops.yaml`, age-encrypted.

## Installing the CA

    # Debian / Ubuntu
    sudo cp nggocnn-homelab-ca.crt /usr/local/share/ca-certificates/
    sudo update-ca-certificates

    # Firefox keeps its own store: Settings -> Privacy & Security ->
    # Certificates -> View Certificates -> Authorities -> Import

    # Android: Settings -> Security -> Encryption & credentials ->
    # Install a certificate -> CA certificate
    # NOTE: Android 7+ does not trust user-installed CAs for app traffic,
    # only for browsers. Mobile apps talking to *.nggocnn.io will still refuse.

## Renewal

The CA expires 2036-08-23; the wildcard expires 2028-11-28. Reissue the
wildcard with `infra/pki/issue-wildcard.sh` before it lapses — nothing renews
automatically, which is the cost of an internal CA over ACME.
