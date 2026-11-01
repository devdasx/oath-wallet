# Coldcards Krise um schwache Seeds: Komplexität ist nicht gleich Sicherheit

Oath Research · September 3, 2026

https://oathwallet.org/de/articles/coldcard-weak-seed-crisis-complexity-verifiable-wallet-security

Beim Coldcard-Vorfall von 2026 wurden die Geräte keineswegs aus der Ferne kompromittiert. Er legte etwas Grundlegenderes offen: Ein ausgeklügeltes Gehäuse kann keinen Seed schützen, der schon bei seiner Entstehung vorhersehbar war.

Forschungsnotiz, 3. September 2026. Dieser Artikel unterscheidet zwischen bestätigten Fakten, Angaben des Anbieters, On-Chain-Schätzungen und unserer eigenen Analyse. Coinkites formeller technischer Post-Mortem-Bericht war bei der Erstellung dieses Artikels noch nicht veröffentlicht. Die Verlustsummen änderten sich, als Ermittler weitere Transaktionen zuordneten; die nachstehenden Zahlen sind daher datierte Momentaufnahmen und keine abschließende Bilanz.

Im Juli 2026 verschwanden Bitcoin-Bestände von Tausenden Adressen, deren Eigentümer glaubten, ihre Schlüssel seien durch Coldcard-Hardware-Wallets geschützt. Die erste und wichtigste Richtigstellung ist zugleich die aufschlussreichste: Die Geräte wurden nicht aus der Ferne kompromittiert. Ein Firmwarefehler hatte die Zufallswerte geschwächt, die bei der Erstellung einiger Wallets verwendet wurden. Angreifer konnten den verkleinerten Schlüsselraum andernorts durchsuchen, mögliche private Schlüssel rekonstruieren, daraus abgeleitete Adressen mit der öffentlichen Bitcoin-Blockchain abgleichen und passende Guthaben ausgeben, ohne die Hardware zu berühren.

Ein Tresor kann physisch äußerst widerstandsfähig sein und dennoch versagen, wenn das darin verwahrte Geheimnis von Anfang an vorhersehbar war.

Dieser Vorfall ist daher weit über einen einzelnen Anbieter hinaus bedeutsam. Er stellt eine bequeme Verkürzung infrage: Hardware bedeute Sicherheit, mehr Komponenten bedeuteten mehr Schutz und eine lange Funktionsliste bedeute ein hohes Maß an Gewissheit. Keine dieser Aussagen ist ein Bedrohungsmodell. Sicherheit entsteht aus dem Gesamtsystem – Entropie, Firmware, Hardware, Build-Prozess, Distribution, Benutzeroberfläche, Backups, Bedienverhalten und physische Sicherheit – sowie aus Belegen, anhand derer Außenstehende seine Aussagen prüfen können.

## Was bei Coldcard geschah

In seiner [offiziellen Sicherheitswarnung](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) erklärt Coinkite, dass die betroffene Firmware einen fehlerhaften Pfad zur Seed-Erzeugung verwendete. Wallet-Seeds, die auf Mk2- oder Mk3-Geräten mit Firmware 4.0.1 bis 4.1.9 erzeugt wurden, waren gefährdet, sofern nicht genügend private, unabhängige Würfelentropie hinzugefügt worden war oder eine starke, eindeutige BIP39-Passphrase eine zusätzliche Barriere geschaffen hatte. Die Warnung umfasst auch Seeds, die auf Mk4-, Mk5- und Q-Geräten vor deren korrigierten Standard- oder Edge-Versionen erzeugt wurden. Für diese späteren Geräte meldete Coinkite etwa 72 Bit Entropie statt der vorgesehenen 128 Bit.

Der Fehler entstand in einer im März 2021 veröffentlichten Firmware und blieb jahrelang latent. Der Hardwareschutz erfüllte seine Funktion für das ihm übergebene Geheimnis; das Problem bestand darin, dass der Prozess zur Erzeugung dieses Geheimnisses nicht die erwartete Unvorhersagbarkeit lieferte. Sobald Angreifer plausible Seeds mit vertretbarem Aufwand systematisch durchprobieren konnten, bot die öffentliche Blockchain einen perfekten Zugehörigkeitstest: Adressen ableiten, auf Guthaben prüfen und mit jedem rekonstruierten Schlüssel signieren. Weder eine Phishing-Aufforderung noch eine USB-Sitzung, ein gestohlenes Paket oder physischer Zugriff waren erforderlich.

### Warum schwache Entropie katastrophal ist

Ein Wallet-Seed ist nicht deshalb sicher, weil er auf einen Menschen zufällig wirkt. Er ist sicher, wenn kein Angreifer die zugrunde liegenden Möglichkeiten mit vertretbarem Aufwand unterscheiden oder vollständig durchprobieren kann. Jedes Bit Entropie verdoppelt den Suchraum. Der Rückgang von 128 Bit auf 72 Bit macht einen Seed nicht nur „etwas schwächer“; er beseitigt 56 Verdopplungsstufen des Arbeitsaufwands. Ein noch kleinerer effektiver Suchraum verwandelt eine astronomisch unmögliche Suche in ein Ingenieurprojekt.

Die Wiederherstellungswörter bleiben syntaktisch gültig. Die Adressen sehen gewöhnlich aus. Die Hardware signiert normal. Backups lassen sich korrekt wiederherstellen. Dies ist ein stiller Fehler: Jedes sichtbare Ritual kann gelingen, obwohl die Sicherheitsgrundlage bereits zusammengebrochen ist. Genau deshalb erfordert die Zufallszahlenerzeugung deterministische Tests der Verdrahtung, Instrumentierung der Entropiequelle auf realen Geräten und Release-Nachweise, die den geprüften Quellcode mit der ausgelieferten Firmware verbinden.

### Der Diebstahl erfolgte in Wellen

Am 30. Juli wurden bei der ersten gemeldeten Leerung innerhalb von ungefähr 25 Minuten rund 594 BTC von etwa 500 Adressen transferiert. Spätere Zuordnungen vergrößerten den bekannten Umfang des Vorfalls. Eine [am 5. August veröffentlichte Bewertung von TRM Labs](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) bezifferte den damaligen Zwischenstand auf knapp 1.816 BTC – zu diesem Zeitpunkt etwa 116 Millionen USD – aus mehr als 5.200 Adressen in vier Wellen. Andere Ermittler wandten andere Bestätigungsregeln an und meldeten später leicht abweichende Summen. Diese Zahlen sind daher als Beleg für das Ausmaß zu lesen, nicht als endgültig feststehende Bilanz.

Auf Coinkites [aktueller Seite zum Sicherheitsstatus](https://coldcard.com/security/status) heißt es ausdrücklich, dass der formelle Post-Mortem-Bericht noch in Arbeit ist; sie behauptet nicht, jeder gemeldete Verlust sei einzeln zugeordnet worden. Diese Unsicherheit ist kein Grund, den Vorfall herunterzuspielen. Sie ist ein Grund, die Unterschiede zwischen verifiziertem Mechanismus, beobachteten Transaktionen, analytischer Zuordnung und abschließendem forensischem Befund zu wahren.

## Ein Firmware-Update repariert keinen alten Seed

Diesen operativen Sachverhalt dürfen betroffene Nutzer nicht übersehen. Korrigierte Firmware berichtigt die künftige Seed-Erzeugung; sie kann einem bereits bestehenden Seed nicht rückwirkend Entropie hinzufügen. Ein Wallet, das aus diesem Seed auf neuer Hardware wiederhergestellt wird, bleibt unter der Kontrolle desselben anfälligen Geheimnisses. Weder ein Austausch des Metallgehäuses noch die Installation einer mobilen App oder das Übertragen der Wörter zu einer anderen Marke ändert den Schlüssel. Die Guthaben müssen auf Adressen verschoben werden, die von einem neu erzeugten und unabhängig geschützten Seed abgeleitet sind.

Wie am 3. September 2026 verifiziert, führte Coldcards Statusseite Mk4/Mk5 Standard 5.6.1 und Q Standard 1.5.1Q als empfohlene Standardversionen auf. Die Mindestversionen mit Korrektur waren Mk2/Mk3 4.2.0 oder höher; Mk4/Mk5 Standard 5.6.0 oder höher; Q Standard 1.5.0Q oder höher; Mk4/Mk5 Edge 6.6.0X oder höher; und Q Edge 6.6.0QX oder höher. Die Release-Kanäle sind relevant: Eine numerisch höhere Edge-Version ist nicht automatisch einer korrigierten Standardversion gleichzusetzen.

### Falls Sie betroffen sein könnten

- 

Verlassen Sie sich nicht länger auf das Gehäuse. Stellen Sie fest, welches Modell, welcher Release-Kanal und welche Firmware bei der Seed-Erzeugung verwendet wurden und ob die offizielle Ausnahme für unabhängige Würfelentropie eindeutig greift. Behandeln Sie den Seed im Zweifel als betroffen.

- 

Nutzen Sie ausschließlich offizielle Anleitungen. Rufen Sie die Coldcard-Warnung und die Seite zum Sicherheitsstatus direkt auf, prüfen Sie signierte Firmware und veröffentlichte Hashes und weisen Sie unaufgeforderte „Migrationshilfe“ zurück. Kein seriöser Helfer benötigt Ihre Wiederherstellungsphrase.

- 

Erzeugen Sie in einer korrigierten Umgebung einen vollständig neuen Seed. Bearbeiten Sie die alte Phrase nicht, mischen Sie ihre Wörter nicht neu und hängen Sie keine Wörter an. Ein neues Wallet benötigt neue Entropie. Bei einem erheblichen Guthaben sollten Sie eine unabhängige Implementierung oder eine sachgerecht konzipierte Multisignatur-Richtlinie erwägen, damit der Seed-Pfad eines einzelnen Anbieters nicht die einzige Vertrauenswurzel bleibt.

- 

Überprüfen Sie die Wiederherstellung vor der Einzahlung. Halten Sie das Backup vertraulich fest, stellen Sie es in einem kontrollierten Verfahren wieder her und bestätigen Sie den erwarteten öffentlichen Fingerabdruck oder die Empfangsadresse. Ein nie getestetes Backup ist eine bloße Annahme.

- 

Übertragen Sie zunächst einen kleinen Testbetrag und dann den Rest. Prüfen Sie Zieladresse und Bestätigung, bevor Sie den vollständigen Betrag übertragen. Vermeiden Sie übereilte Improvisation, aber verwechseln Sie ruhiges Vorgehen nicht mit der Erlaubnis, die Migration eines offengelegten Seeds aufzuschieben.

- 

Nehmen Sie den alten Seed außer Betrieb. Ein Firmware-Update und eine später hinzugefügte starke Passphrase reparieren ihn nicht. Bewahren Sie Aufzeichnungen auf, die für steuerliche oder rechtliche Zwecke erforderlich sind, ohne unnötige Kopien des Geheimnisses zu behalten.

Coinkite zufolge lieferten mindestens 50 faire, unabhängige und private Würfe im betroffenen Arbeitsablauf „Add Dice Rolls“ allein aus den Würfeln mindestens 128 Bit; 99 oder mehr Würfe lieferten etwa 256 Bit. Auf die genauen Bedingungen kommt es an. Wurde die Folge aufgezeichnet, beobachtet, verzerrt oder nicht unabhängig erzeugt oder bestehen Zweifel, darf aus der bloßen Anzahl keine Sicherheit abgeleitet werden. Eine starke, bereits zuvor bestehende BIP39-Passphrase kann eine zusätzliche Barriere bilden; Coinkite empfiehlt dennoch die Migration und beschreibt eine Passphrase nicht als Reparatur des Seeds.

## Das Gerät wurde nicht gehackt – und genau darin liegt die tiefere Warnung

Jeden Verlust als „Hardware-Wallet-Hack“ zu bezeichnen, verdichtet mehrere unterschiedliche Fehlerklassen zu einer dramatischen Formulierung. Dadurch werden die Schutzmaßnahmen verschleiert, die geholfen hätten. Beim Coldcard-Vorfall überwand der Angreifer weder das Gehäuse, das Tastenfeld, die USB-Kontrollen noch das Secure Element im Besitz des jeweiligen Opfers. Er umging das Gerät, weil sich das Stammgeheimnis systematisch durchsuchen ließ.

Eine Sicherheitsgrenze schützt nur, was sie passiert. Wenn der in ein Secure Element eingebrachte Schlüssel schwach ist, wenn bösartige Firmware ihn über Signaturen preisgibt, wenn der Bildschirm ein vom Angreifer kontrolliertes Ziel anzeigt oder wenn eine Person zur Autorisierung einer Übertragung gezwungen wird, stellt die Existenz dedizierter Hardware keine Antwort auf diesen Angriff dar.

## Verluste mit Hardware-Wallets folgen nicht alle demselben Muster

Mehrere dokumentierte Vorfälle und Forschungsdemonstrationen zeigen, warum diese Kategorie Präzision erfordert. Sie beweisen nicht, dass Hardware-Wallets nutzlos sind. Sie zeigen, dass Hardware das Risiko in ein anderes System aus Chips, Firmware, Lieferketten, Host-Software, Signierprotokollen, Backups und menschlichen Abläufen verlagert.

### 1. Fehlerinjektion und physische Extraktion des Seeds

Im Jahr 2020 [legte Kraken Security Labs](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) eine Technik mit Spannungs-Glitching gegen Trezor-One- und Model-T-Geräte offen. Kraken berichtete, dass etwa 15 Minuten physischer Zugriff die Extraktion verschlüsselten Seed-Materials ermöglichen könnten und eine kurze PIN anschließend durch Brute Force ermittelt werden könne. Als praktische Gegenmaßnahme nannte Kraken eine starke BIP39-Passphrase, die nicht auf dem Gerät gespeichert wird. Kraken dokumentierte eine ähnliche Angriffsklasse gegen KeepKey.

Dies ist eine andere Bedrohung als bei Coldcard. Sie erfordert den Besitz des Zielgeräts und eine Fehlerinjektion unter Laborbedingungen. Sie zeigt, dass Manipulationsresistenz vom gewählten Mikrocontroller und Speicherkonzept abhängt und dass eine PIN nicht zwangsläufig ein Verschlüsselungsgeheimnis mit hoher Entropie ist.

### 2. Kompromittierte Software im Umfeld eines echten Hardware-Signers

Im Dezember 2023 schleuste der [Lieferkettenvorfall beim Ledger Connect Kit](https://www.ledger.com/blog/security-incident-report) Schadcode in dApps ein, die ein kompromittiertes Paket luden. Laut Ledger brachte der Code EVM-Nutzer dazu, Transaktionen zu signieren, die ihre Wallets leerten. Die Hardwaregeräte gaben ihre Seeds nicht von selbst preis; das sie umgebende System legte legitimen Unterzeichnern bösartige Transaktionen zur Signatur vor.

Diese Fehlerklasse zeigt, warum „der Schlüssel hat das Gerät nie verlassen“ zwar notwendig, aber nicht hinreichend ist. Ein sicherer Schlüssel kann zuverlässig die falsche Transaktion autorisieren, wenn Nutzer, Host oder Anzeige nicht verlässlich erkennen können, was signiert wird. Eindeutige Transaktionsdekodierung, vertrauenswürdige Anzeigen, eng begrenzte Berechtigungen, Kontrollen für Abhängigkeiten und Widerstand gegen blindes Signieren gehören zur Sicherheit der Selbstverwahrung.

### 3. Bösartige Firmware, die Geheimnisse über normale Signaturen preisgibt

Forscher von Block haben [einen praktischen Forschungsangriff veröffentlicht](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet), bei dem kompromittierte Wallet-Firmware geheimes Material verdeckt in scheinbar normalen Signaturen codiert. Ihr Bedrohungsmodell setzt eine Kompromittierung der Firmware über Wege wie einen Lieferkettenangriff, eine Insiderhandlung, eine Kompromittierung des Build-Systems oder des Signierschlüssels voraus. Eine physische Trennung vom Netz hilft nicht, wenn die signierte Transaktion selbst zum Exfiltrationskanal wird.

Hier gewinnen reproduzierbare Builds, mehrere unabhängige Build-Ersteller, festgeschriebene Abhängigkeiten, Secure Boot und Vielfalt bei Multisignatur-Implementierungen an Bedeutung. Sie schützen bestimmte Glieder einer Kette. Sie zertifizieren weder das Design noch den Quellcode oder den Betreiber auf magische Weise.

### 4. Offenlegung von Backups, Austausch von Adressen und Zwang

Viele reale Diebstähle nutzen niemals Schwächen im Silizium aus. Angreifer stehlen oder fotografieren Seed-Backups, ersetzen eine Empfangsadresse, geben sich als Support aus, kompromittieren einen Kauf- oder Versandprozess, erlangen ein Gerät samt schwacher PIN oder zwingen den Eigentümer zur Mitwirkung. Die Wiederherstellungsphrase ist konstruktionsbedingt ein portables Master-Zugangsmerkmal: Wer sie erlangt, kann das Wallet andernorts wiederherstellen – unabhängig davon, wo sich das ursprüngliche Gerät befindet.

## Warum mehr Komplexität die Sicherheit verschlechtern kann

Komplexität ist mitunter gerechtfertigt. Eine separate Anzeige kann die Transaktionsprüfung vertrauenswürdiger machen. Ein Secure Element kann die Kosten einer physischen Extraktion erhöhen. Multisignatur kann verhindern, dass ein einzelner Schlüssel den Ausfallpunkt bildet. Doch jeder zusätzliche Mechanismus schafft auch Schnittstellen, Zustände, Aktualisierungspfade, Abhängigkeiten, Wiederherstellungsverfahren und Annahmen. Die richtige Frage lautet nicht: „Ist das komplex?“ Sie lautet: „Welche Bedrohung kontrolliert jede Komponente, und welche neuen Fehlermöglichkeiten führt sie ein?“

Das klassische Prinzip der [Sparsamkeit des Mechanismus](https://www.ojp.gov/ncjrs/virtual-library/abstracts/protection-information-computer-systems) nach Saltzer und Schroeder besagt, dass Schutzkonzepte so einfach und klein wie möglich sein sollten, damit ihre Prüfung und ihr Verständnis praktikabel bleiben. Moderne [NIST-Leitlinien zur Systemsicherheit](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-160v2r1.pdf) behandeln die Verringerung der Angriffsfläche sowie große, schwer analysierbare Multifunktionskomponenten ebenfalls als architektonische Anliegen. Einfachheit bedeutet nicht die Abwesenheit von Schutzmaßnahmen. Sie ist die Weigerung, Schutzmaßnahmen hinzuzufügen, deren Verhalten sich nicht erklären, prüfen und korrekt betreiben lässt.

- 

Mehr Code schafft mehr mögliche Fehler. Er verteuert außerdem eine vollständige Prüfung und erschwert es, Wechselwirkungen nachzuvollziehen.

- 

Mehr Betriebsarten erhöhen das Konfigurationsrisiko. Standard- und Edge-Firmware, mehrere Abläufe zur Seed-Erzeugung, Passphrase-Wallets, USB- und Air-Gap-Pfade sowie verschiedene Backup-Varianten können für sich genommen jeweils sicher sein, in ihrer Kombination aber Verwirrung stiften.

- 

Mehr Schnittstellen schaffen Übersetzungsrisiken. Hardwareanzeige, Host-App, QR-Format, microSD-Arbeitsablauf, Browser-Connector und Netzwerk-Backend müssen exakt darin übereinstimmen, was der Nutzer autorisiert.

- 

Mehr Verfahrensaufwand kann die Befolgungsbereitschaft mindern. Ist der sichere Weg schwierig, überspringen Menschen Prüfungen, verschieben Updates, verwenden Backups erneut oder folgen Notfallanweisungen, ohne sie zu verstehen.

- 

Mehr Vertrauen kann Verluste vergrößern. Ein als „cold“, „air-gapped“ oder „unhackbar“ vermarktetes Produkt kann Nutzer dazu bewegen, mehr Werte hinter einem einzigen Seed zu bündeln. Konzentration verwandelt einen verborgenen Fehler in ein katastrophales Ergebnis.

Tiefenverteidigung ist wertvoll, wenn die Schichten unabhängig sind. Die Wiederholung derselben Implementierung, derselben Entropiequelle, desselben Anbieters oder desselben Wiederherstellungsgeheimnisses ist keine unabhängige Verteidigung.

## Open Source, Audits, reproduzierbare Builds und KI-Prüfung sind keine Synonyme

Der Fall Coldcard ist besonders lehrreich, weil die Firmware öffentlich war und eine Dokumentation zu reproduzierbaren Builds existierte, während der anfällige Pfad jahrelang Bestandteil veröffentlichter Versionen blieb. Daraus folgt nicht, dass Offenheit nutzlos wäre. Es zeigt vielmehr, dass die Verfügbarkeit von Belegen und die tatsächliche Untersuchung der richtigen Eigenschaft zwei verschiedene Dinge sind.

- 

Open Source bedeutet, dass Außenstehende die Implementierung prüfen können. Es belegt weder, dass jemand jeden sicherheitskritischen Pfad überprüft hat, noch dass der öffentliche Quellbaum das installierte Binärprogramm hervorgebracht hat.

- 

Ein unabhängiges Audit ist ein begrenzter Prüfauftrag. Sein Wert hängt vom benannten Prüfer, dem genauen Commit oder der Version, dem Bedrohungsmodell, den geprüften Eigenschaften, Ausschlüssen, Befunden und Nachweisen der Fehlerbehebung ab. „Auditiert“ ohne Geltungsbereich ist ein Slogan.

- 

Ein reproduzierbarer Build ermöglicht unabhängigen Parteien, einer veröffentlichten Anleitung zu folgen und die Ergebnisse zu vergleichen. Eine Übereinstimmung kann den Quellcode mit einem Release-Artefakt verbinden; sie beweist nicht, dass der Quellcode korrekt ist.

- 

App-Store-Prüfung und Codesignierung schaffen Kontrollen für Verteilung und Plattform. Sie beweisen für sich allein nicht, dass ein App-Store-Binärprogramm Bit für Bit einem öffentlichen Repository entspricht.

- 

KI-gestützte Prüfung kann große Codebasen durchsuchen, adversariale Hypothesen erzeugen, Invarianten vergleichen und menschliche Analysen beschleunigen. Ein Modell kann jedoch auch Kontext übersehen, eine falsche Prämisse akzeptieren oder einen plausiblen, aber unzutreffenden Befund erzeugen. KI-Prüfung ist eine weitere Perspektive, keine Zertifizierungsinstanz.

Coldcards aktuelle Statusseite verwendet vorbildlich präzise Formulierungen zum Prüfumfang: Sie nennt gezielte RNG-Instrumentierung auf realen Geräten, Quellcode-Reviews, ein Hotfix-Review sowie einen reproduzierbaren Build mit Nachverfolgung des Würfelpfads und erklärt anschließend ausdrücklich, dass diese Prüfungen weder ein vollständiges Audit sämtlicher Firmware-Binärprogramme darstellen noch Fehlerfreiheit garantieren. Dieser Satz ist wertvoller als ein uneingeschränktes Gütesiegel.

## Was Oath wahrheitsgemäß behaupten kann

Oath beruht auf einer anderen Verwahrungsarchitektur: einer iPhone- und iPad-Anwendung mit öffentlich einsehbarem Quellcode anstelle eines dedizierten Hardware-Signers. Das [öffentliche Repository](https://github.com/devdasx/oath-wallet) stellt den mobilen Client und Build-Anleitungen unter der MIT-Lizenz bereit. Das [veröffentlichte Sicherheitsmodell](https://oathwallet.org/data/security-model.json) besagt, dass Wallet-Geheimnisse über den app-spezifischen iOS-Schlüsselbund mit der Schutzklasse „nur dieses Gerät“ gespeichert werden, während die lokale Datenbank opake Referenzen statt Wiederherstellungsphrasen oder privater Schlüssel enthält. Transaktionen werden auf dem Gerät erstellt und signiert, bevor signierte Daten an die Netzwerkinfrastruktur gesendet werden.

Apples [Dokumentation zur Plattformsicherheit](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) beschreibt verpflichtende Codesignierung, identifizierte Entwickler, automatische und menschliche App-Store-Prüfung, Sandboxing und die Erzwingung von Signaturen zur Laufzeit. Die [Keychain-Dokumentation](https://support.apple.com/guide/security/secb0694df1a/1/web/1) beschreibt den Schutz einzelner Einträge und die Beteiligung der Secure Enclave an der Handhabung von Keychain-Schlüsseln. Dies sind reale Plattformkontrollen. Sie stellen nicht die Behauptung auf, Oaths private Blockchain-Schlüssel seien selbst Secure-Enclave-Schlüssel; Oath erhebt diese Behauptung ebenfalls nicht.

### Kann Oath sicherer sein als ein Hardware-Wallet?

Für manche Bedrohungsmodelle ja. Als allgemeingültige Behauptung nein. Ein Smartphone-Wallet kann den Herstellungs- und Versandweg eines dedizierten Geräts vermeiden, die Zahl der Gegenstände verringern, die wertvolle Selbstverwahrung sichtbar signalisieren, eine Plattform mit schnellen signierten Updates und ausgereiftem Sandboxing nutzen und eine prüfbare Implementierung in einer vertrauten Oberfläche bereitstellen, die Nutzer mit größerer Wahrscheinlichkeit korrekt bedienen. Ein kleinerer Funktionsumfang kann zudem ganze Klassen von Risiken durch Browser, Swaps, Autorisierungen und unterschiedliche Interpretationen zwischen Geräten beseitigen.

Für andere Bedrohungsmodelle ist ein gut konzipierter separater Signer eine wichtige Grenze. Ist das Betriebssystem des Smartphones oder der Wallet-Prozess kompromittiert, können physische Trennung und eine unabhängig vertrauenswürdige Anzeige verhindern, dass ein vernetzter Host einen Schlüssel erlangt oder missbraucht. Bei institutionellen Werten oder Beträgen, deren Verlust die Lebensumstände verändern würde, kann die stärkere Architektur eine sorgfältig getestete Multisignatur-Richtlinie mit unabhängigen Implementierungen, unabhängiger Entropie, getrennten Standorten und dokumentierter Wiederherstellung sein – kein Wettstreit zwischen einem Smartphone und einem Hardwaregerät.

Das Wort „Hardware“ sollte die Analyse daher niemals beenden. Auch ein iPhone ist Hardware. Entscheidend ist, welcher Code ausgeführt wird, wie er gebaut und verteilt wurde, wo Geheimnisse verfügbar sind, was Nutzer verifizieren können, wie Transaktionen angezeigt werden, wie Updates erfolgen und welche einzelnen Fehler zum Transfer von Guthaben führen können.

### Die Evidenzgrenze gilt auch für Oath

Auf Oaths Website heißt es derzeit, die App sei unabhängig auditiert und reproduzierbar gebaut. Das [öffentliche Audit-Register](https://oathwallet.org/security) ist als maßgebliche Stelle für die Namen der Prüfer, den genauen Umfang, Daten, geprüfte Versionen, Berichte, Befunde, Fehlerbehebungen, Hashes und Materialien zur Reproduzierbarkeit ausgewiesen. Zum Zeitpunkt der Veröffentlichung zeigte dieses Register diese konkreten Artefakte noch nicht an. Das öffentliche GitHub-Repository enthielt außerdem keine Release-Artefakte, anhand derer sich eine Übereinstimmung mit dem App-Store-Binärprogramm unabhängig reproduzieren ließe.

Daher behauptet dieser Artikel weder, dass „jede Zeile des App-Store-Binärprogramms nachweislich sicher ist“, noch dass mehrere Unternehmen jedes Verhalten zertifiziert hätten oder dass KI die gesamte Anwendung verifiziert habe. Solche Aussagen gingen über die öffentlich verfügbaren Belege hinaus. Technisch korrekt ist die Unterscheidung, dass der Quellcode auf GitHub veröffentlicht wird, während Apple über den App Store ein signiertes, kompiliertes Binärprogramm vertreibt. Um beides miteinander zu verknüpfen, sind eine öffentliche Build-Anleitung, eine unveränderliche Quellcode-Revision, festgeschriebene Abhängigkeiten, ein gesichertes App-Store-Artefakt, ein Normalisierungsverfahren für die Auswirkungen von Apples Signierung, ein übereinstimmendes Ergebnis und eine unabhängige Attestierung erforderlich.

Verifikation ist am stärksten, wenn eine Aussage genügend Belege enthält, damit ein skeptischer Außenstehender sie reproduzieren kann. Oath sollte ebenso streng nach diesem Maßstab beurteilt werden wie jeder Hardware-Wallet-Anbieter.

## Was ein Verifikationspaket auf Universitätsniveau enthalten sollte

Für Forschende, Auditoren, Journalisten und institutionelle Prüfer sollte eine glaubwürdige Aussage zur Wallet-Sicherheit eine navigierbare Beweiskette statt einer Wand aus Gütesiegeln sein. Verlangen Sie mindestens Folgendes:

- 

Ein präzises Bedrohungsmodell. Benennen Sie Fernkompromittierung, physische Extraktion, bösartige Updates, Kompromittierung des Build-Systems, schwache Entropie, Transaktionsaustausch, Backup-Diebstahl, Zwang und Verfügbarkeit getrennt.

- 

Eine unveränderliche, geprüfte Revision. Benennen Sie den Commit, den Abhängigkeitsgraphen, Compiler- und SDK-Versionen, Build-Flags, Entitlements und die Konfiguration, die im Prüfumfang lagen.

- 

Ein benannter unabhängiger Bericht. Veröffentlichen Sie den Prüfer, die Methodik, Daten, Ausschlüsse, Schweregradkriterien, Befunde und die Belege, anhand derer jeder Befund als behoben abgeschlossen wurde.

- 

Reproduzierbarkeit vom Quellcode zum Binärprogramm. Stellen Sie eine vollständige Anleitung und unabhängige Build-Ergebnisse bereit, die an die exakte öffentliche Version gebunden sind. Erläutern Sie alle nicht deterministischen oder durch Signierung erzeugten Unterschiede.

- 

Nachweise zum Entropiepfad. Testen Sie die Entropiequelle auf realer Hardware, überprüfen Sie das Fehlerverhalten, lassen Sie keinen stillen Rückfall auf einen Ersatzpfad zu und verfolgen Sie den genauen Pfad, den der Release-Build verwendet. Statistische Ausgabetests allein können nicht beweisen, dass der Generator korrekt angebunden war.

- 

Adversariale Transaktionstests. Testen Sie den Austausch des Empfängers, Gebührenmanipulation, feindselige Metadaten, Grenzen des blinden Signierens, unterbrochene Broadcasts und abweichende Parserinterpretationen zwischen jeder Anzeige und jedem Signer.

- 

Übungen zu Wiederherstellung und Updates. Testen Sie die Anleitungen unter realistischem Zeitdruck, einschließlich unvollständiger Informationen, alter Versionen, Migration, verlorener Geräte und der Möglichkeit, dass ein Update bestehende Geheimnisse nicht reparieren kann.

- 

Kontinuierliche, vielfältige Prüfung. Nutzen Sie deterministische Tests, statische Analyse, menschliche Fachleute, Fuzzing, Tests auf realen Geräten und KI-gestützte Prüfung als komplementäre Methoden. Halten Sie fest, was jede Methode belegt und was sie nicht belegt hat.

## Die Bedrohung kann den Bildschirm verlassen

Selbstverwahrung kann einen Verwahrer entbehrlich machen, aber auch eine Person zur letzten Autorisierungsgrenze machen. Ein Dieb, der die Kryptografie nicht brechen kann, nimmt möglicherweise stattdessen den Eigentümer, dessen Familie, Zuhause, Arbeitsplatz oder öffentliche Identität ins Visier. Dedizierte Hardware kann diese Zielauswahl bisweilen erleichtern, weil sie sichtbar signalisiert, dass jemand Selbstverwahrung ernst nimmt, oder weil sie einen physischen Gegenstand schafft, den ein Angreifer zu finden erwartet. Auch ein Smartphone kann Bestände offenbaren, wenn Guthaben sichtbar sind. Keine der beiden Bauformen löst das Problem des Zwangs.

Eine 2024 begutachtete Studie, [„Untersuchung von Wrench Attacks: physische Angriffe auf Nutzer von Kryptowährungen“](https://doi.org/10.4230/LIPIcs.AFT.2024.10), analysierte Interviews, Foren und 146 Nachrichtenartikel. Ihr gefilterter Nachrichtendatensatz enthielt 105 Vorfälle physischer Angriffe, darunter 24 Entführungen und 6 Morde als vorrangig gemeldete Taten. Die Autoren betonen die Untererfassung und stellten fest, dass auch erfahrene Sicherheitsfachleute nicht immun waren. Diese Zahlen beschreiben den Datensatz der Studie, nicht die weltweite Inzidenzrate, und belegen nicht, dass ein bestimmter Wallet-Typ jeweils die Tat verursacht hat.

Die Gefahr ist nicht theoretisch. Im Jahr 2024 beschrieb das [Justizministerium der Vereinigten Staaten](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) Verurteilungen im Zusammenhang mit einer Verschwörung, bei der Überwachung, gewaltsame Wohnungseinbrüche, Entführung, Körperverletzung und Drohungen eingesetzt wurden, um Opfer zum Leeren ihrer Kryptowährungskonten zu zwingen. Die Lehre lautet weder, in Panik zu geraten, noch sich legitimer Hilfe zu entziehen. Vielmehr müssen operative Privatsphäre und persönliche Sicherheit als Teil des Wallet-Designs behandelt werden.

### Menschliche Sicherheit hat Vorrang vor der Wiedererlangung von Vermögenswerten

- 

Machen Sie Guthaben oder Aufbewahrungsdetails nicht öffentlich. Öffentliche Adressen, Screenshots, Gespräche auf Konferenzen, Beiträge in sozialen Medien, Versandunterlagen und entsorgte Verpackungen können Identität, Standort und vermutetes Vermögen miteinander verknüpfen.

- 

Trennen Sie Alltagsguthaben von Reserven. Ein Wallet für laufende Ausgaben sollte weder die gesamte langfristige Position offenlegen noch kontrollieren. Vermeiden Sie es, sämtliche Vermögenswerte und Wiederherstellungswege hinter einem einzigen, sofort zugänglichen Geheimnis zu bündeln.

- 

Nutzen Sie für erhebliche Werte eine unabhängige Autorisierung. Eine gut konzipierte Multisignatur-Lösung kann verhindern, dass ein gestohlenes Gerät oder Zwang an einem einzelnen Standort allein ausreicht – allerdings nur, wenn Schlüssel, Implementierungen und Wiederherstellungsmaterialien tatsächlich getrennt sind.

- 

Schützen Sie, was die Benutzeroberfläche offenbart. Nutzen Sie App-Sperre und Datenschutzkontrollen für den App-Umschalter, zeigen Sie vollständige Guthaben nicht öffentlich an und prüfen Sie Empfänger, ohne unbeteiligte Bestände offenzulegen.

- 

Planen Sie mit qualifizierten Fachleuten vor Ort. Besonders gefährdete Personen und Institutionen sollten gemeinsam mit Fachleuten, die ihre Rechtsordnung und persönlichen Umstände verstehen, rechtmäßige Verfahren für physische Sicherheit, Reisen, Reaktion auf Vorfälle, Nachlass und Sicherheit der Familie entwickeln.

- 

Riskieren Sie niemals ein Leben für ein Wallet. Keine Wiederherstellungsphrase, kein Gerät, keine Transaktion und kein Betrag ist eine körperliche Verletzung wert. Priorisieren Sie bei einer unmittelbaren Bedrohung die Sicherheit von Menschen und kontaktieren Sie die örtlichen Notdienste, sobald dies gefahrlos möglich ist.

## Die Lehre lautet Evidenz, nicht Lagerdenken

Coldcards Versagen beweist weder, dass jede aktuelle Coldcard unsicher ist, noch dass jedes Hardware-Wallet bloßes Theater oder jedes Smartphone-Wallet überlegen ist. Coinkite hat korrigierte Versionen, Migrationsanleitungen, gezielte unabhängige Validierung und ausdrückliche Grenzen dessen veröffentlicht, was diese Prüfungen belegen. Eine verantwortungsvolle Analyse sollte sowohl die Schwere des Vorfalls als auch die dokumentierten Abhilfemaßnahmen anerkennen.

Ebenso wenig sollte Oath allein dadurch Vertrauen erben, dass es eine andere Architektur kritisiert. Der öffentliche Quellcode, das eng begrenzte Verwahrungsmodell, Apples Plattformkontrollen, lokales Signieren und die Prüfbarkeit sind bedeutsam. Sie gewinnen an Stärke, wenn ein benannter Dritter Prüfumfang und Befunde veröffentlicht, wenn Forschende das verteilte Binärprogramm aus unveränderlichem Quellcode reproduzieren können und wenn KI-gestützte Prüfung mit deterministischen Tests und verantwortlichem menschlichem Urteil verbunden wird.

Die dauerhafte Schlussfolgerung ist einfacher: Sicherheit ist nicht das Material des Gehäuses; sie ist die Qualität des Geheimnisses, das Verhalten des Gesamtsystems, die Unabhängigkeit seiner Verteidigungsschichten, die Klarheit seiner Benutzeroberfläche und die verfügbare Evidenz zur Überprüfung jeder wichtigen Aussage. Komplexität kann notwendig sein, doch sie muss sich ihren Platz verdienen, indem sie eine Bedrohung nach der anderen nachweislich kontrolliert.

Lesen Sie als Nächstes Oaths Leitfäden zum [Create your first wallet](https://help.oathwallet.org/articles/create-wallet), zu [BIP39-Passphrasen](https://oathwallet.org/articles/add-bip39-passphrase-oath-wallet), zum [Sicherheitsmodell der Selbstverwahrung](https://oathwallet.org/articles/what-never-leaves-iphone-oath-self-custody-security-model) und zu [App-Passcode und Datenschutzkontrollen](https://oathwallet.org/articles/lock-oath-down-passcode-face-id-auto-lock-app-switcher-privacy).

## Primärquellen und technische Quellen

- 

[Coinkite: Coldcard-Sicherheitswarnung](https://blog.coinkite.com/coldcard-mk3-seed-generation-warning/) – betroffene Versionen, Entropieumfang, korrigierte Releases und Migrationsanleitung.

- 

[Coldcard: aktueller Sicherheitsstatus](https://coldcard.com/security/status) – aktuelle Releases, Umfang der unabhängigen Validierung, Einschränkungen und Status des Post-Mortem-Berichts.

- 

[TRM Labs: On-Chain-Bewertung vom 5. August](https://www.trmlabs.com/resources/blog/the-largest-hardware-wallet-exploit-of-2026-inside-the-usd-116-million-coldcard-hack) – datierte Verlustschätzung und Analyse der Transaktionsflüsse.

- 

[Kraken Security Labs: Offenlegung der Trezor-Fehlerinjektion](https://blog.kraken.com/product/security/kraken-identifies-critical-flaw-in-trezor-hardware-wallets) – Seed-Extraktion bei physischem Zugriff und Passphrase als Gegenmaßnahme.

- 

[Ledger: Bericht zum Connect-Kit-Vorfall](https://www.ledger.com/blog/security-incident-report) – Veröffentlichung einer bösartigen Abhängigkeit und Auswirkungen auf das Signieren durch Nutzer.

- 

[Block: Forschung zu Firmware-Hintertüren](https://engineering.block.xyz/blog/got-your-keys-got-your-coins-how-to-backdoor-a-bitcoin-wallet) – Exfiltration von Geheimnissen durch Signaturen und Gegenmaßnahmen in der Lieferkette.

- 

[Apple Platform Security: App-Sicherheit und Codesignierung](https://support.apple.com/guide/security/intro-app-security-ios-ipados-visionos-secf49cad4db/web) – iOS-Distribution, Sandboxing und Kontrollen der Laufzeitintegrität.

- 

[Ordekian, Atondo-Siu, Hutchings und Vasek: Studie zu Wrench Attacks](https://doi.org/10.4230/LIPIcs.AFT.2024.10) – begutachtete Analyse der physischen Sicherheit.

- 

[US-Justizministerium: Verurteilungen wegen gewaltsamer Wohnungseinbrüche im Zusammenhang mit Kryptowährungen](https://www.justice.gov/archives/opa/pr/man-convicted-violent-home-invasion-robberies-steal-cryptocurrency) – dokumentierter physischer Zwang und Überwachung.

Oath ist weder mit Coldcard, Coinkite, Trezor, Kraken, Ledger, Block noch den zitierten Forschenden verbunden und wird von keiner dieser Parteien unterstützt. Produkt- und Unternehmensnamen gehören ihren jeweiligen Eigentümern. Dieser Artikel dient der Sicherheitsaufklärung und ist keine individuelle finanzielle, rechtliche oder Notfallberatung. Geben Sie niemals eine Wiederherstellungsphrase, einen privaten Schlüssel, eine Wallet-Passphrase, einen App-Passcode oder ein Backup-Passwort an eine Website, einen Supportmitarbeiter, Forschende oder einen KI-Assistenten weiter.
