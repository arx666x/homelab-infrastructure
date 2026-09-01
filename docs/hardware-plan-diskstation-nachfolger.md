# Hardware-Bauvorschlag: Synology-Diskstation-Nachfolger (TrueNAS, ~75TB netto)

**Datum:** 2026-09-01
**Status:** Einkaufsempfehlung, Preise vor Bestellung verifizieren (Marktlage sehr volatil, s. §6)
**Kontext:** Diese Session ist der Nachfolger der Konzeptdiskussion aus "Hausautomatisierung
Verbrauchsoptimierung" (Dezember 2025). Auslöser: Plattenausfall in der alten Diskstation
(192.168.11.55), keine Firmware-Updates von Synology mehr, alte Platten mit hohem
Ausfallrisiko, plus grundsätzlicher Unmut über Synologys Plattensperre (nur noch
Synology-zertifizierte/-gelieferte Platten). Nicht zu verwechseln mit **musicbox**
(TrueNAS SCALE, 192.168.11.53) - das ist die bereits laufende, kleinere TrueNAS-Box für
Navidrome/Airsonic/Musikbibliothek (s. `docs/myhomeismycastle-cert-distribution-konzept.md`)
und bleibt von diesem Bauvorschlag unberührt.

---

## 1. Warum dieser Vorschlag vom Dezember-Plan abweicht

Der Dezember-2025-Plan (unten in der Anfrage zitiert) war ein reiner All-NVMe-RAIDZ2-Pool
(8x8TB M.2 über ToughArmor-Backplane, ~5.500€). Das war Ende 2025 machbar. Seitdem hat sich
die Speicherpreis-Lage grundlegend verändert:

- NAND-Flash-Vertragspreise sind zwischen Q4 2025 und Q2 2026 etwa das 4,2-4,5-fache
  gestiegen. Consumer-NVMe liegt im August 2026 bei ~104,50€/TB im Median (vorher ~68,75€/TB),
  bei kleineren Kapazitäten (1TB) sogar 145-180€/TB. Grund: Hersteller lenken 70-80% ihrer
  NAND-Produktion in KI-Rechenzentren um.
- ECC-Server-RAM (DDR4 wie DDR5) ist streckenweise kaum noch verfügbar; Server-DRAM ist laut
  Marktbeobachtern in Q1 2026 um 80-110% gestiegen. DDR4 ist zwar der "günstigere" Ausweg
  gegenüber DDR5, aber auch dort ist die Versorgungslage angespannt.
- Analysten (u.a. Lenovo) rechnen erst ab 2030 wieder mit Preisen auf Vor-2025-Niveau.

Ein 8x8TB-NVMe-Pool würde heute nicht mehr ~3.600€ kosten, sondern eher **7.000-9.000€ nur
für die SSDs** - das erklärt einen guten Teil der Verdopplung von ~10.000€ auf ~20.000€+, die
du beobachtet hast.

**Deshalb der Kurswechsel, den du selbst schon vorschlägst:** große HDDs als Kapazitätsträger
+ ein SSD-"Cache" (technisch: ZFS Special-vdev, dazu mehr in §3) für die Antwortzeiten. HDDs
sind von der NAND-Krise nicht betroffen und haben ihre eigene, deutlich moderatere
Preisentwicklung. Das bringt den Gesamtpreis wieder in einen bezahlbaren Bereich - siehe §6,
wo die Summe bei einem Bruchteil deiner ~20.000€-Erwartung landet, nicht weil ich optimistisch
runde, sondern weil All-Flash aktuell schlicht der teuerste Zeitpunkt der letzten Jahre ist und
ein HDD/SSD-Hybrid diesem Preisschock gezielt ausweicht.

---

## 2. Zielkonflikt und Kompromiss

| Ziel | All-Flash (Dez-2025-Plan) | HDD+Special-vdev (dieser Vorschlag) |
|---|---|---|
| ~75TB netto bezahlbar | ✗ aktuell ~15.000-18.000€ allein für SSDs | ✓ s. §6 |
| Sehr schnelle Antwortzeiten | ✓✓ (aber unbezahlbar) | ✓ für Metadaten/kleine Dateien (das, was "Antwortzeit" im Alltag ausmacht); Bulk-Durchsatz bleibt HDD-Niveau (~180-220MB/s pro Platte, mehrere parallel deutlich mehr) |
| Nachrüstbarkeit | teuer (NVMe-Slots begrenzt) | ✓ sehr gut, s. §4 |
| Stromkosten runter | ✓✓ (SSDs ~0W idle) | ⚠️ ehrlich gesagt: **nicht deutlich niedriger** als die alte Diskstation, s. §7 - das war die realistischste Erwartung, die ich korrigieren muss |

Der einzige Punkt, den ich offen relativieren muss: Die ursprüngliche Hoffnung "sehr leise,
deutlich weniger Strom" war an das All-SSD-Konzept geknüpft. Mit rotierenden 24TB-Platten fällt
der Stromvorteil gegenüber einer alten Diskstation kleiner aus als gedacht - er ist trotzdem
vorhanden (moderne Exos-Enterprise-Platten + effiziente EPYC-Plattform ist besser als eine
10 Jahre alte Synology mit altem PSU-Wirkungsgrad), aber nicht der große Sprung, den reines
Flash gebracht hätte. Details und Zahlen in §7.

---

## 3. Architektur

### 3.1 Kapazitäts-Layer: HDD-Pool

**RAIDZ2 über 24TB-Enterprise-HDDs** (Seagate Exos X24, CMR, 7200rpm). RAIDZ2 statt RAIDZ1,
weil du selbst schon einen Ausfall hattest und mit weiteren rechnest - zwei Platten dürfen
gleichzeitig sterben, ohne dass der Pool weg ist, plus Zeit für einen Resilver ohne
Herzrasen.

- **24TB-Rohkapazität pro Platte = 21,83 TiB formatiert.**
- **Start: 5x 24TB RAIDZ2** (3 Datenplatten + 2 Parität) → **~65,5 TiB ≈ 72TB netto**.
  Das ist praktisch genau deine eigene Vorgabe (5 Platten) und liegt knapp unter 75TB.
- **Ausbaustufe (später, sobald budgetär sinnvoll): 6. Platte per RAIDZ-Expansion
  nachrüsten** → 4 Datenplatten → **~87,3 TiB ≈ 96TB netto**. Kein neuer Vdev nötig, keine
  Neuformatierung, kein Datenverlust - siehe §4.

  *Warum nicht gleich 6 Platten kaufen?* Reine Kostenfrage (~950-1.100€ pro 24TB-Platte,
  s. §6) - wenn das Budget es hergibt, ist "gleich 6" der bessere Start (mehr Spindeln =
  mehr IOPS/Durchsatz, sofort komfortabel über 75TB). Ich liste beide Varianten in §6.

### 3.2 Antwortzeiten-Layer: Special-vdev statt reinem "SSD-Cache"

Du hattest "SSD Cache" im Kopf - technisch gibt es dafür in ZFS zwei sehr unterschiedliche
Bausteine, und die Wahl entscheidet, ob sich "schnellere Antwortzeiten" wirklich einstellen:

- **L2ARC** (reiner Lesecache): hilft nur bei wiederholt gelesenen, großen Datenmengen, braucht
  viel RAM zur Indizierung, verpufft bei den für "Antwortzeit" typischen Vorgängen (Ordner
  öffnen, `ls`, Thumbnails, Snapshots durchsuchen) fast wirkungslos.
- **Special vdev (Metadaten + Small-Blocks)**: **das ist der richtige Baustein für dein
  Ziel.** Alle Metadaten (Verzeichnisstrukturen, Dateisystem-Baum, Snapshots) und - mit
  gesetztem `special_small_blocks`-Threshold - auch kleine Dateien (Fotos-Thumbnails,
  Konfigdateien, kleine Dokumente) landen dauerhaft auf NVMe statt auf der rotierenden
  Platte. Das ist genau das, was sich im Alltag als "spürbar schneller" anfühlt - Ordner mit
  vielen Dateien öffnen sich sofort, `find`/Backups/Snapshots sind kein Wartespiel mehr,
  während der große Datenstrom (Videos, große Backups) weiter über die HDDs läuft, wo er
  ohnehin am günstigsten liegt.

  **Wichtig:** Ein Special-vdev ist kein Cache, sondern dauerhafter Pool-Speicher - fällt er
  aus, ist der ganze Pool weg. Deshalb zwingend **gespiegelt (Mirror)**, mit mindestens der
  gleichen Redundanz wie der Hauptpool (bei RAIDZ2 idealerweise 3-way-Mirror, minimal
  vertretbar 2-way).

  **Dimensionierung:** Für Metadaten allein reichen 0,3-1% der Poolgröße. Mit
  Small-Block-Einschluss (empfohlen, das ist der eigentliche Antwortzeit-Gewinn) eher
  3-5%. Bei ~72-96TB Pool sind das ~2-5TB *nutzbar*. Dein Bauchgefühl "~8TB" ist also eher
  großzügig bemessen (gut für Kleindateien-lastige Nutzung wie Fotos/Dokumente/VM-Configs) -
  ich liste beide Stufen in §6.

  **Laufwerkswahl:** Enterprise-NVMe mit Power-Loss-Protection (PLP), nicht Consumer-SSD -
  ein Special-vdev bekommt sehr viele kleine Schreibzugriffe (Metadaten-Updates), das
  zerstört Consumer-TLC-SSDs auf Dauer und ohne PLP drohen bei Stromausfall
  Metadaten-Inkonsistenzen im ganzen Pool. Gebrauchte Rechenzentrums-SSDs (z.B. Samsung
  PM983 U.2, 3,84TB) sind hier aktuell das beste Preis-Leistungs-Verhältnis - Gebrauchtmarkt
  ist von der NAND-Krise deutlich weniger betroffen als Neuware, und PLP/Enterprise-Endurance
  bringen sie ohnehin mit.

### 3.3 Boot-Pool

Kleiner, gespiegelter Boot-Pool (2x günstige SATA-SSD, 250-500GB) - TrueNAS SCALE will das
so, und Redundanz beim Booten kostet fast nichts.

### 3.4 Netzwerk

Deine Dream Machine Pro hat bereits einen 10G-SFP+-Port (aktuell vermutlich als WAN2 oder frei
als LAN-Port nutzbar - bitte einmal in der UniFi-Oberfläche prüfen, das kann ich nicht von hier
aus sehen). Wenn der frei ist: eine gebrauchte Dual-Port-10G-NIC (Intel X520-DA2) in die
TrueNAS-Box, ein DAC-Kabel zur Dream Machine, fertig - kein zusätzlicher Switch nötig.

Falls du mehr als einen 10G-Anschluss brauchst (z.B. auch dein Arbeitsplatzrechner direkt mit
10G anbinden, oder die k3s-Worker perspektivisch), lohnt sich ein kleiner
MikroTik-SFP+-Switch (CRS305-1G-4S+ oder CRS309-1G-8S+) als Aggregation - siehe §6 als
optionale Position.

**Warum das für "Antwortzeiten" zählt:** Deine aktuelle Diskstation hängt vermutlich an
1GbE (~110MB/s real). Selbst der beste ZFS-Pool bringt nichts, wenn das Netzwerk der
Flaschenhals bleibt. 10G ist hier kein Luxus, sondern die Voraussetzung dafür, dass du den
Special-vdev-Gewinn überhaupt spürst.

---

## 4. Nachrüstbarkeit (dein explizites Kriterium)

Das ist der Kern-Vorteil dieses Layouts gegenüber "gleich alles kaufen":

1. **HDD-Kapazität:** RAIDZ-Expansion (OpenZFS 2.3+, in TrueNAS SCALE seit 24.10 produktiv -
   musicbox läuft schon auf 25.10 "GoldenEye", also definitiv verfügbar für die neue Box) er-
   laubt, **einzelne Platten** zu einem bestehenden RAIDZ-vdev hinzuzufügen, ohne Neuanlage
   des Pools. Start mit 5 Platten, bei Bedarf 6., 7., 8. Platte einzeln nachkaufen - jede
   einzelne Platte muss nur einmal bezahlt werden, kein "Vdev-Paar" nötig wie bei klassischem
   Striping.
2. **Gehäuse-Reserve:** Ich schlage bewusst ein Gehäuse mit 8-10 Bays vor, obwohl nur 5-6
   Platten Tag 1 verbaut werden - genau für diese Expansion, ohne Gehäusewechsel.
3. **PCIe-Lanes:** Ein EPYC-Board (ROMED8-2T) hat 7x PCIe-x16-Slots plus reichlich
   SlimSAS/OCuLink-Anbindung - Reserve für weitere NVMe, eine schnellere NIC (25G/40G später)
   oder eine zusätzliche HBA, falls doch mehr als die onboard-Ports gebraucht werden.
4. **RAM:** Start bewusst mit 32GB ECC (2 Module), 2 Slots frei für spätere Aufstockung auf
   64GB+, **sobald sich die RAM-Preise beruhigen** - siehe §6, das ist aktuell der teuerste
   Einzelposten pro GB und der Punkt, wo "warten" sich am meisten lohnt.
5. **Special-vdev:** Als Mirror einzeln austauschbar - eine SSD nach der anderen gegen größere
   tauschen (Resilver), Kapazität wächst automatisch nach dem letzten Tausch, ohne
   Neuanlage.

---

## 5. Stückliste

| Komponente | Modell | Menge | Zweck |
|---|---|---|---|
| Mainboard | ASRock Rack ROMED8-2T (SP3, EPYC 7002/7003, onboard 2x 10GbE, 7x PCIe x16) | 1 | Plattform |
| CPU | AMD EPYC 7302P (16C/32T, 155W TDP, effizient im Idle) | 1 | Ausreichend für ZFS/SMB/NFS, kein Overkill |
| RAM | 32GB ECC DDR4-3200 RDIMM (2x16GB), 2 Slots frei für Ausbau | 1 Kit | ZFS ARC |
| Gehäuse | Fractal Design Define 7 XL (bis zu 10+ 3,5"-Bays je nach Bracket-Bestückung, sehr leise) | 1 | Reserve für RAIDZ-Expansion |
| Netzteil | be quiet! Straight Power 850W (80+ Platinum, modular) | 1 | Anlaufstrom für 5-8 HDDs gleichzeitig |
| Gehäuselüfter | Noctua NF-A12x25 PWM | 4 | Leise Kühlung |
| HDD | Seagate Exos X24 24TB, CMR, SATA | 5 (später 6-8) | RAIDZ2-Pool |
| Special-vdev-SSD | Samsung PM983 3,84TB U.2 NVMe (gebraucht, Enterprise/PLP) | 2 (Mirror) | Metadaten + Small-Blocks |
| U.2-Adapter/Kabel | PCIe-x4-zu-U.2 (SFF-8639) Adapterkarte | 2 | Anbindung Special-vdev-SSDs |
| Boot-SSD | 2x 250GB SATA-SSD (Mirror) | 2 | TrueNAS-Boot-Pool |
| Netzwerk | Intel X520-DA2 Dual-10G-SFP+ (gebraucht) + DAC-Kabel | 1+1 | 10G-Anbindung an Dream Machine |
| *(optional)* | MikroTik CRS305-1G-4S+ (4x SFP+) | 1 | Nur falls kein freier 10G-Port an der Dream Machine |
| Kleinteile | SATA-Stromkabel/-Splitter, Schrauben, Kabelbinder | - | - |

**Hinweis onboard-SATA:** Das ROMED8-2T bringt SATA-Anbindung über die SlimSAS-Ports der
CPU direkt mit - für 5-6 HDDs sollte das ohne separate HBA reichen (bitte vor Bestellung im
Board-Handbuch die genaue Portzahl/Kabelbelegung gegenprüfen, das spart im Idealfall die
~250-300€ für eine zusätzliche Broadcom-9400-16i-Karte).

---

## 6. Kostenschätzung (Stand: Web-Recherche 01.09.2026, D-Markt)

**Wichtiger Vorbehalt:** Die Preise unten stammen aus einer aktuellen Web-Recherche
(Geizhals/Preisvergleich-Aggregatoren), nicht aus einer Live-Bestellung. Gerade RAM und
NVMe-SSDs schwanken derzeit teils wochenweise deutlich. **Vor der Bestellung unbedingt
Tagespreise auf geizhals.de / mindfactory.de / alternate.de gegenprüfen.**

### Variante A - Start-Budget (5 HDDs, kleiner Special-vdev, 32GB RAM)

| Position | Geschätzter Preis |
|---|---|
| ASRock Rack ROMED8-2T | ~550-650€ |
| AMD EPYC 7302P | ~400-450€ |
| RAM 32GB ECC DDR4 (2x16GB) | ~250-350€ |
| Fractal Define 7 XL | ~195-220€ |
| be quiet! Straight Power 850W | ~170-190€ |
| 4x Noctua NF-A12x25 | ~110-120€ |
| 5x Seagate Exos X24 24TB (~1.000€/Stk.) | ~4.750-5.500€ |
| 2x Samsung PM983 3,84TB (gebraucht) | ~1.400-1.650€ |
| 2x U.2-Adapterkarte | ~70-90€ |
| 2x Boot-SSD 250GB | ~70-90€ |
| Intel X520-DA2 + DAC-Kabel | ~90-110€ |
| Kleinteile/Puffer | ~100-150€ |
| **Zwischensumme (ohne Versand/MwSt.-Puffer)** | **~8.150-9.520€** |

→ **~72TB netto**, Tag-1-Fähigkeit für den Antwortzeiten-Sprung (Special-vdev + 10G), Rest
folgt per Nachrüstung.

### Variante B - Komfort-Start (6 HDDs, größerer Special-vdev, 64GB RAM)

| Position | Geschätzter Preis |
|---|---|
| Wie Variante A, aber: | |
| RAM 64GB ECC DDR4 (2x32GB) statt 32GB | ~500-650€ (statt ~250-350€) |
| 6x statt 5x Exos X24 24TB | ~5.700-6.600€ (statt ~4.750-5.500€) |
| 2x Samsung PM983 7,68TB statt 3,84TB | ~2.800-3.400€ (statt ~1.400-1.650€) |
| **Zwischensumme** | **~11.500-13.500€** |

→ **~96TB netto**, größerer Metadaten-/Small-Block-Puffer (näher an deinem "~8TB
Cache"-Bauchgefühl), sofort mehr Kapazitäts- und RAM-Reserve, kein 6.-Platten-Nachkauf nötig.

**Beide Varianten liegen deutlich unter deiner ~20.000€-Erwartung.** Das ist kein
Rechentrick - der Hauptkostentreiber der Preisexplosion ist NAND-Flash (SSDs), und dieser
Vorschlag verlagert die Kapazität bewusst auf HDDs, die von der aktuellen Krise kaum betroffen
sind. Der einzige Bereich, wo die Krise wirklich zuschlägt (ECC-RAM, Special-vdev-NVMe), ist
hier klein gehalten bzw. auf den Gebrauchtmarkt verlagert.

Falls am Ende doch näher an 20.000€ gebraucht/gewollt wird, sind die sinnvollsten
Erweiterungen in dieser Reihenfolge: (1) Variante B statt A, (2) Special-vdev auf 3-way-Mirror
statt 2-way (mehr Redundanz), (3) 128GB statt 64GB RAM, (4) direkt 8 statt 6 Platten. Ich würde
davon abraten, das Budget einfach "aufzubrauchen" - das Ziel "bezahlbar" war ausdrücklich
Priorität.

---

## 7. Stromkosten-Schätzung

Ehrliche Einordnung vorweg (s. §2): Der große Stromvorteil des ursprünglichen All-SSD-Plans
entfällt mit rotierenden Platten größtenteils. Grobe Rechnung für Variante A:

| Komponente | Idle-Leistung (geschätzt) | Last-Leistung (geschätzt) |
|---|---|---|
| Plattform (EPYC 7302P + Board + RAM + Lüfter) | ~50-70W | ~140-180W |
| 5x Exos X24 24TB (HDD) | ~30-35W (5x ~6W) | ~50W (5x ~10W) |
| 2x Special-vdev-NVMe | ~8-12W | ~15-20W |
| 10G-NIC | ~4-6W | ~8W |
| **Gesamt** | **~95-125W** | **~215-260W** |

Bei überwiegendem Idle-Betrieb (typisches Homelab-Nutzungsmuster, gelegentliche Lastspitzen
bei Backups/Scrubs) als grobe Schätzung ~110W Dauerlast-Äquivalent:

```
110W × 24h × 365 Tage / 1000 = 964 kWh/Jahr
964 kWh × 0,35€/kWh (aktueller D-Durchschnitt, ~31-37 ct je nach Anbieter, Stand 09/2026)
≈ 337€/Jahr
```

Zum Vergleich: Eine 10+ Jahre alte Synology mit 4-5 älteren Enterprise-Platten und einem
ineffizienten internen Netzteil liegt oft in ähnlicher Größenordnung (grob 60-100W
Dauerlast) - der Stromkosten-Vorteil dieses Umbaus ist also eher **moderat, nicht
dramatisch**. Der eigentliche Gewinn liegt bei Antwortzeiten, Kapazität, Nachrüstbarkeit und
Unabhängigkeit von Synologys Plattensperre - Strom würde ich nicht als Hauptargument für den
Umbau verkaufen, auch wenn er nicht schlechter wird.

Ein spürbarer Stromgewinn wäre nur mit deutlich weniger/kleineren Platten oder echtem All-Flash
zu erreichen gewesen - beides würde aber gegen "75TB" bzw. "bezahlbar" laufen. Das ist der
Zielkonflikt aus §2, den man an dieser Stelle konkret bezahlt.

---

## 8. Migrationshinweis

Nicht Teil dieses Hardware-Vorschlags, aber wichtig für die Reihenfolge: Die Diskstation
versorgt aktuell u.a. Pi-hole-DNS (192.168.11.55) und dient laut `docs/GIT-WORKFLOW.md`/
Commit-Historie auch als NFS-Backup-Ziel für den k3s-Cluster (Longhorn-Backups). Vor dem
physischen Abbau der alten Diskstation müssen diese Rollen (DNS-Fallback, Backup-Ziel)
explizit auf die neue Box umgezogen werden - sonst reißt das im laufenden Betrieb ab. Das ist
ein eigenes, separates Vorhaben, sobald die neue Hardware steht.

---

## Quellen (Recherche 01.09.2026)

- [Seagate Exos X X24 24TB – Geizhals](https://geizhals.de/seagate-exos-x-x24-24tb-st24000nm007h-a3050652.html)
- [RAM-Preise Mai 2026 – PCGH](https://www.pcgameshardware.de/RAM-Hardware-154108/Specials/Speicher-Preise-im-Mai-2026-1534291/)
- [RAM-Preise 2026 – CSL](https://www.csl-computer.com/blog/2025/12/10/ram-preise-2025-2026-ursachen-auswirkungen-fur-kaufer/)
- [SSD-Preise 2026 – Monsterdealz](https://www.monsterdealz.de/magazin/ssd-preise)
- [SSD-Preise 2026 – Caseking Blog](https://www.caseking.de/blog/ssd-preise-steigen)
- [DDR4 ECC RDIMM Prices 2026 – DatacenterDisk](https://datacenterdisk.com/server-ram/ddr4)
- [Refurbished DDR4 Server Memory 2026 – PCSP](https://pcserverandparts.com/news/refurbished-ddr4-server-memory-2026-server-ram-price-crisis/)
- [AMD Epyc 7302P – Geizhals](https://geizhals.de/amd-epyc-7302p-100-000000049-a2114784.html)
- [Broadcom HBA 9400-16i – Geizhals](https://geizhals.de/broadcom-hba-9400-16i-05-50008-00-a1717529.html)
- [Fractal Design Define 7 – Geizhals](https://geizhals.de/fractal-design-define-7-v12856.html)
- [Samsung PM983 3.84TB gebraucht – eBay](https://www.ebay.com/itm/356661582522)
- [UniFi Dream Machine Pro Tech Specs](https://techspecs.ui.com/unifi/cloud-gateways/udm-pro?subcategory=all-cloud-gateways)
- [Strompreis aktuell 2026 – BDEW/rechnerportal](https://www.rechnerportal.net/news/bdew-haushaltsstrompreis-2026/)
