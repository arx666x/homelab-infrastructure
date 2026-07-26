# Diskstation (DSM) OIDC-Login gegen Authentik - manueller Schritt

DSM ist kein Kubernetes-Workload, sondern ein eigenständiges Gerät mit
eigener Web-UI - die SSO-Anbindung passiert komplett in der DSM-Oberfläche,
nicht per GitOps. Authentik-seitig ist alles schon vorbereitet: Provider
`diskstation-oidc-provider` in
[`gitops/config/authentik/blueprints-configmap.yaml`](../gitops/config/authentik/blueprints-configmap.yaml).

Ursprünglich als "technisch nicht möglich" eingestuft (TrueNAS SCALE hat
tatsächlich kein natives OIDC) - DSM 7.1.1-42962 hat es aber sehr wohl
(Screenshot vom 2026-07-26 bestätigt: **Systemsteuerung → Domain/LDAP →
SSO-Client → OpenID Connect SSO-Dienst**), keine 7.2 nötig wie zuerst
recherchiert.

## Werte für die DSM-Maske

Erst den Authentik-Provider live prüfen (Well-Known-URL erst nach dem ersten
Blueprint-Sync abrufbar):

```
https://sso.reckeweg.io/application/o/diskstation/.well-known/openid-configuration
```

| DSM-Feld | Wert |
|---|---|
| Profil | oidc |
| Name | authentik (oder frei wählbar) |
| Wellknown URL | `https://sso.reckeweg.io/application/o/diskstation/.well-known/openid-configuration` |
| Anwendungs-ID | `diskstation` |
| Anwendungsschlüssel | `DISKSTATION_OIDC_CLIENT_SECRET` aus der lokalen Scratchpad-Datei (nicht im Repo, nicht in diesem Dokument - siehe Chat) |
| Umleitungs-URI | `https://diskstation.reckeweg.io:5001` |
| Autorisierungsbereich | `openid profile email` |
| Benutzeranspruch | `preferred_username` |

**Wichtig laut offizieller Authentik-Doku**
([integrations.goauthentik.io/infrastructure/synology-dsm](https://integrations.goauthentik.io/infrastructure/synology-dsm/)):
die Umleitungs-URI ist bewusst NUR der Origin ohne Pfad - DSM matcht sie nur
gegen Host- und HTTPS-Header, ein `#/signin`-Suffix o.ä. würde den Abgleich
brechen.

## Bekannte Stolperfalle: Benutzer-Mapping

`preferred_username` aus dem Authentik-Token muss zu einem bestehenden
lokalen (oder AD/LDAP-)DSM-Benutzernamen passen, sonst schlägt der Login
nach erfolgreichem Authentik-Auth mit einem DSM-eigenen "Benutzer nicht
gefunden"-Fehler fehl - analog zur Guacamole-Falle
(`POSTGRESQL_AUTO_CREATE_ACCOUNTS=false`, siehe
[guacamole.yaml](../gitops/config/guacamole/guacamole.yaml)), nur dass DSM
so einen Account grundsätzlich nicht automatisch anlegt. Vor dem ersten
Test-Login prüfen, dass Authentiks `preferred_username`-Claim für den
verwendeten Account exakt einem vorhandenen DSM-Benutzernamen entspricht.

## Bekanntes Problem: gmkt-01x-DNS

Beim Testen (2026-07-26) aufgefallen, unabhängig vom SSO-Rollout: Pi-hole
(192.168.11.55) löst `gmkt-01x.reckeweg.io` fälschlich auf die
Traefik-LoadBalancer-IP (`192.168.20.100`) auf statt auf die eigene
Node-IP - `gmkt-02x`/`gmkt-03x` funktionieren korrekt. Betrifft NICHT DSM
direkt, aber falls ihr für den Headlamp-OIDC-Schritt
([docs/headlamp-oidc-setup.md](headlamp-oidc-setup.md)) per Hostname auf
`gmkt-01x` zugreifen wollt: bis der Pi-hole-Eintrag korrigiert ist, stattdessen
die IP direkt nutzen (`192.168.20.31`, siehe `ansible/inventory/hosts.ini`,
Feld `ansible_host` von `master01`).
