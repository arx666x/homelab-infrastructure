# Authentik: Wiederherstellung und sichere Passkey-Konfiguration

Diese Anleitung beschreibt, wie Sie nach einem Login-Loop das Authentik-System auf den Standard-Flow zurücksetzen und anschließend Passkeys als optionale, passwortlose Alternative für Ihre Benutzer einrichten.

## 1. Tenant auf den funktionierenden Standard zurücksetzen

Um den aktuellen Login-Loop zu durchbrechen und das System wieder benutzbar zu machen, biegen wir den Haupt-Einstiegspunkt (Tenant) auf den originalen Authentik-Ablauf zurück.

1. Öffnen Sie die noch aktive Administrator-Sitzung im Browser.
2. Navigieren Sie im linken Menü zu **System** -> **Tenants**.
3. Suchen Sie Ihren aktiven Tenant (standardmäßig `authentik-default`) und klicken Sie rechts auf **Edit**.
4. Suchen Sie das Feld **Authentication flow**.
5. Wählen Sie im Dropdown-Menü den originalen Flow aus: `default-authentication-flow`.
6. Klicken Sie unten auf **Update**, um die Änderungen zu speichern.

*Testen Sie den Login nun in einem privaten Browserfenster (Inkognito-Modus) mit Ihrem herkömmlichen Benutzernamen und Passwort. Der Login muss jetzt wieder fehlerfrei funktionieren.*

---

## 2. Passkeys sicher im Standard-Flow integrieren

Anstatt Passwörter komplett zu verbieten (was zum Aussperren führt), konfigurieren wir den Standard-Flow so, dass er Passkeys erkennt. Nutzer mit Passkey loggen sich passwortlos ein – alle anderen nutzen weiterhin ihr Passwort.

1. Navigieren Sie im Admin-Interface zu **Flows & Stages** -> **Flows**.
2. Klicken Sie auf den Eintrag `default-authentication-flow`.
3. Wechseln Sie im oberen Bereich auf den Reiter **Stage Bindings**.
4. Suchen Sie die erste Stufe in der Liste (meist **Order 10**) mit dem Namen `default-authentication-identification`.
5. Klicken Sie rechts neben dieser Stage auf **Edit Stage**.
6. Konfigurieren Sie die Stage im geöffneten Fenster exakt wie folgt:
   * **Password stage**: Stellen Sie sicher, dass hier `default-authentication-password` ausgewählt ist (damit das Passwort-Feld für herkömmliche Logins geladen wird).
   * **Passkey Settings**: Suchen Sie das Feld **WebAuthn Authenticator Validation Stage** und wählen Sie im Dropdown den Eintrag `default-authentication-mfa-validation` aus.
   * **Passkey Autofill (WebAuthn Conditional UI)**: Aktivieren Sie diese Checkbox (falls in Ihrer Authentik-Version sichtbar), um dem Browser zu erlauben, gespeicherte Passkeys direkt beim Klick in das Benutzernamen-Feld vorzuschlagen.
7. Klicken Sie auf **Update**, um die Stage zu speichern.

---

## 3. Ersten Passkey als Benutzer registrieren

Da das System nun vorbereitet ist, können Sie Ihren persönlichen Passkey hinterlegen und die passwortlose Funktion testen.

1. Melden Sie sich aus dem Admin-Interface ab oder öffnen Sie die normale Benutzer-Oberfläche (User Interface) von Authentik.
2. Loggen Sie sich mit Ihrem normalen Passwort ein.
3. Klicken Sie oben rechts auf Ihren **Benutzernamen** oder Ihr Profilbild und wählen Sie **Settings**.
4. Wechseln Sie auf den Reiter **MFA Devices**.
5. Suchen Sie den Bereich **WebAuthn Devices / Passkeys** und klicken Sie auf **Enroll**.
6. Geben Sie dem Gerät einen Namen (z. B. "Mein Smartphone" oder "YubiKey").
7. Es öffnet sich das native Fenster Ihres Betriebssystems oder Browsers. Bestätigen Sie die Erstellung des Passkeys mittels PIN, Touch ID, Face ID oder Ihrem Passwortmanager.

---

## 4. Den passwortlosen Login testen

1. Loggen Sie sich aus Authentik aus.
2. Rufen Sie die Login-Maske erneut auf.
3. Klicken Sie in das Feld **Username / Email**.
4. **Ergebnis**: Ihr Browser oder Passwortmanager sollte Ihnen nun direkt Ihren registrierten Passkey vorschlagen. Sobald Sie diesen auswählen und bestätigen (z. B. per Fingerabdruck), loggt Authentik Sie sofort ein, ohne dass Sie jemals ein Passwort eintippen mussten.
