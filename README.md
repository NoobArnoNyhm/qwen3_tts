# Qwen3-TTS lokal mit Weboberflaeche

Qwen3-TTS und ein eigener Whisper-STT-Dienst laufen in separaten Linux-Dockercontainern auf Windows mit WSL2. Die Qwen-Oberflaeche ist die offizielle Gradio-Demo. Keine separate Python-Installation auf Windows erforderlich. Das Setup ist unabhaengig von Whisper-Containern anderer Projekte.

## Voraussetzungen

- Docker Desktop mit aktiviertem WSL2-Backend und Linux-Containern; Docker Compose v2 mit `up --wait`.
- WSL2 und ein aktueller NVIDIA-Windows-Treiber mit CUDA-12.8-Unterstuetzung. Kein separater Linux-Grafiktreiber in WSL erforderlich.
- Eine CUDA-faehige NVIDIA-GPU mit ausreichend freiem VRAM. Standard ist das kleinere 0.6B-Modell; bei Speichermangel andere GPU-Anwendungen schliessen. 1.7B-Modelle brauchen mehr Speicher.
- Internet fuer Image-, Paket- und Modelldownload beim ersten Start sowie mehrere GB freier Speicherplatz.

## Start in Windows PowerShell

```powershell
.\Start-Qwen3TTS.ps1
```

Falls die lokale PowerShell-Ausfuehrungsrichtlinie das Skript blockiert, einmalig fuer diesen Aufruf:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Qwen3TTS.ps1
```

Danach: <http://localhost:8000>. Das Skript wartet bis zu einer Stunde auf die Weboberflaeche. Beim ersten Start dauern Image-Build und Modelldownload entsprechend laenger. Der Container laeuft anschliessend im Hintergrund. Bei einem Fehler zeigen die Logs die Ursache; ein Timeout stoppt den Container nicht automatisch.

Standardmaessig startet das Base-Modell fuer eigene Stimmen aus Referenzaufnahmen. Die Oberflaeche stammt unveraendert aus dem offiziellen Paket und hat englische/chinesische Beschriftungen. FlashAttention ist nicht erforderlich und deaktiviert; Berechnungen verwenden das von Qwen empfohlene bfloat16. Dafuer ist eine GPU mit bfloat16-Unterstuetzung erforderlich (NVIDIA Ampere oder neuer, z.B. RTX 30/40/50).

```powershell
.\Start-Qwen3TTS.ps1 -Action Logs
.\Start-Qwen3TTS.ps1 -Action Status
.\Start-Qwen3TTS.ps1 -Action Stop
```

Logs mit Strg+C verlassen. Stop entfernt die Container, nicht die lokalen Daten. `restart: unless-stopped` startet den Dienst nach einem Docker-Neustart wieder, sofern er nicht zuvor gestoppt wurde.

## Eigenen Whisper-STT-Dienst starten

Fuer die automatische Stimmerstellung beide Dienste starten:

```powershell
.\Start-Qwen3TTS.ps1
.\Start-QwenWhisper.ps1
```

Der eigene Whisper-Dienst verwendet das separate Compose-Projekt `qwen3-whisper` aus `compose.whisper.yaml`. API: <http://localhost:5001/v1/audio/transcriptions>, API-Dokumentation: <http://localhost:5001/docs>. Der bereits vorhandene Whisper auf Port 5000 gehoert zu einem anderen Setup und wird weder benoetigt noch veraendert. Auf Port 6000 laeuft Piper aus dem anderen Setup; auch dieser Dienst ist fuer die Stimmerstellung und Kapitelverarbeitung nicht erforderlich.

Whisper verwendet standardmaessig das mehrsprachige Modell **small**, **CPU/int8** und vier Threads. Dadurch bleibt die GPU fuer Qwen verfuegbar. Der erste Start laedt das Modell in den eigenen persistenten Cache unter `data/whisper/huggingface`; das Startskript wartet bis zu einer Stunde auf Bereitschaft. Fuer den Whisper-Dienst allein ist keine NVIDIA-GPU erforderlich. Das kompatible Drittanbieter-Image `heimoshuiyu/whisper-fastapi` ist in Compose auf einen festen SHA-256-Digest gepinnt.

```powershell
.\Start-QwenWhisper.ps1 -Action Status
.\Start-QwenWhisper.ps1 -Action Logs
.\Start-QwenWhisper.ps1 -Action Config
.\Start-QwenWhisper.ps1 -Action Stop
```

Diese Aktionen betreffen ausschliesslich den eigenen Whisper-Dienst. Qwen separat mit `Start-Qwen3TTS.ps1` steuern. Stop entfernt die jeweiligen Container, nicht die Modellcaches. Beide Dienste verwenden `restart: unless-stopped`.

Andere Einstellungen sind ueber `-Port`, `-Model` und `-Threads` moeglich:

```powershell
.\Start-QwenWhisper.ps1 -Port 5002 -Model base -Threads 6
```

Zulaessige Whisper-Modelle: `tiny`, `base`, `small`, `medium`, `large-v3`. Groessere Modelle benoetigen mehr RAM, Speicherplatz und CPU-Zeit; `tiny` und `base` sind schneller, aber oft weniger genau. Die Parameter bei jedem erneuten Start wieder angeben, sonst gelten die Standardwerte (Port 5001, Modell small, vier Threads). Bei abweichendem Port `New-QwenVoice.ps1 -WhisperUrl 'http://localhost:5002/v1/audio/transcriptions'` verwenden. Bei belegtem Port einen anderen waehlen; fremde Dienste nicht stoppen.

## Eigene Stimme erstellen und wiederverwenden

1. Im Tab **Save / Load Voice** unter **Save Voice** eine Aufnahme deiner Stimme in **Reference Audio** hochladen oder mit dem Mikrofon aufnehmen.
2. Unter **Reference Text** exakt den in der Aufnahme gesprochenen Text eingeben. **Use x-vector only** fuer bessere Aehnlichkeit ausgeschaltet lassen; ohne Transkript kann die Option aktiviert werden, mit eingeschraenkter Qualitaet.
3. **Save Voice File** anklicken und die erzeugte Stimmdatei herunterladen. Das ist ein wiederverwendbares Stimmprofil, kein neu trainiertes Modell.
4. Unter **Load Voice & Generate** diese Datei hochladen, den neuen **Target Text** eingeben, **German** waehlen und **Generate** anklicken. Die Stimmdatei kann nach einem Neustart erneut geladen werden.

Zum direkten Ausprobieren ohne Stimmdatei gibt es den Tab **Clone & Generate** mit Referenzaudio, Referenztext und Zieltext.

Fuer den Einstieg einen sauberen Ausschnitt von etwa 10 bis 20 Sekunden verwenden: nur deine Stimme, ohne Musik, Hall oder andere Sprecher. Das ist eine praktische Empfehlung, keine feste Laengengrenze. Eine minutenlange Aufnahme ist nicht erforderlich und verbessert die Aehnlichkeit nicht automatisch; lange Aufnahmen brauchen mehr Speicher und Rechenzeit. Bei langen Aufnahmen einen passenden Ausschnitt samt exaktem Transkript verwenden. Sprechweise und Aufnahmequalitaet beeinflussen das Ergebnis; eine identische Stimme ist nicht garantiert.

## Stimme automatisch aus einer MP3 erstellen

Mit PowerShell 7 (`pwsh`), Docker-CLI, laufendem Qwen-Base-Modell und dem eigenen Whisper-Dienst:

```powershell
pwsh -File .\New-QwenVoice.ps1 -AudioPath 'C:\Aufnahmen\meine-stimme.mp3' -Name 'Meine Stimme'
```

Das Skript schneidet zuerst mit FFmpeg im vorhandenen Qwen-Container einen **maximal 20 Sekunden langen Referenzausschnitt** aus der Aufnahme und wandelt ihn in Mono-WAV mit 24 kHz um. Es sendet nur diesen Ausschnitt als Multipart-Upload an Whisper, liest das JSON-Feld `Text` (auch `text` wird akzeptiert), uebertraegt exakt denselben Ausschnitt und das Transkript an Qwens Gradio-API `save_prompt` und laedt das fertige Stimmprofil herunter. FFmpeg auf Windows ist nicht erforderlich. Kein manueller Text und kein Browser erforderlich. Standard: eigener Whisper auf Port **5001** und Qwen auf Port **8000**.

**Wichtig:** Das Profil speichert nicht nur eine kompakte Sprecherkennung, sondern auch Audio-Referenzcodes und Referenztext, die bei jeder Synthese erneut verarbeitet werden. Eine komplette lange Aufnahme ist deshalb ungeeignet: Ein untersuchtes Profil mit rund einer Stunde Referenz machte selbst einen kurzen Text extrem langsam. Mehr Referenzmaterial ist hier kein zusaetzliches Training. Alte ueberlange Profile werden durch die Skriptkorrektur nicht automatisch repariert; unter neuem Namen aus einem kurzen Ausschnitt neu erstellen.

Startposition und Dauer koennen gewaehlt werden, z.B. 15 Sekunden ab Minute 1:

```powershell
.\New-QwenVoice.ps1 -AudioPath '.\aufnahme.mp3' -Name 'Meine Stimme Kurz' `
	-ReferenceStartSeconds 60 -ReferenceSeconds 15
```

`ReferenceSeconds` ist auf 3 bis 30 Sekunden begrenzt; eine kuerzere Quelldatei wird nicht verlaengert. Einen Ausschnitt mit klarer Sprache ohne Musik oder lange Stille waehlen; das Skript sucht nicht automatisch die beste Passage. Dockerzugriff auf den lokalen Qwen-Container ist fuer die Aufbereitung erforderlich. Bei anderem Containernamen `-ContainerName 'mein-qwen-container'` angeben (Standard: `qwen3-tts-qwen3-tts-1`). Eine entfernte `QwenUrl` allein genuegt nicht fuer die lokale Aufbereitung. Temporaere Ausschnitte auf dem Host und im Container werden nach der Verarbeitung entfernt.

Ergebnis relativ zum Projektordner:

```text
data/voices/Meine Stimme/Meine Stimme.pt
data/voices/Meine Stimme/transcript.txt
data/voices/Meine Stimme/reference.json
```

Vorhandene Namen werden nicht ueberschrieben. Bei Fehlern wird kein unfertiges Profil veroeffentlicht. Das Stimmprofil bleibt unabhaengig vom Gradio-Cache und von Container-Neustarts auf dem Host erhalten. Es kann im Tab **Save / Load Voice** unter **Load Voice & Generate** hochgeladen werden; eine automatische Stimmenliste in der Demo wird dadurch nicht angelegt. Die Originalaufnahme wird nicht zusaetzlich archiviert; Upload-Kopien koennen in den API-Caches verbleiben. Aufnahme, Transkript und Profil sind sensible persoenliche Daten.

Andere API-Adressen oder ein anderes Ausgabeverzeichnis:

```powershell
.\New-QwenVoice.ps1 -AudioPath '.\aufnahme.mp3' -Name 'Erzaehler' `
	-WhisperUrl 'http://localhost:5001/v1/audio/transcriptions' `
	-QwenUrl 'http://localhost:8000' -OutputDirectory 'D:\Stimmen'
```

`WhisperUrl` ist der vollstaendige Transkriptionsendpunkt; `QwenUrl` die Basisadresse der Gradio-Oberflaeche. `TimeoutSec` gilt pro HTTP-Aufruf und betraegt standardmaessig 1800 Sekunden. Die API-Verbindung erfolgt vom Host, nicht ueber interne Docker-Containernamen. Whisper-Fehler im Transkript koennen die Qualitaet beeintraechtigen; bei schlechten Ergebnissen das gespeicherte Transkript und die Aufnahme pruefen. Fuer lange Aufnahmen gelten dieselben Speicher- und Qualitaetshinweise wie oben.

Fokussierte Tests ohne laufende Modelle oder zusaetzliche Testpakete:

```powershell
pwsh -File .\tests\New-QwenVoice.Tests.ps1
```

## Ganzes Kapitel mit eigener Stimme vertonen

Die unveraenderte Demo-UI bietet keine automatische Kapitelaufteilung. Dafuer gibt es `Convert-QwenChapter.ps1`: PowerShell 7 auf dem Host und ein laufendes Qwen-Base-Modell genuegen. Kapitel als UTF-8-Textdatei bereitstellen und das zuvor erstellte Stimmprofil verwenden:

```powershell
pwsh -File .\Convert-QwenChapter.ps1 `
	-TextPath 'C:\Buch\Kapitel01.txt' `
	-VoiceFile '.\data\voices\Meine Stimme\Meine Stimme.pt' `
	-OutputPath 'C:\Buch\Audio\Kapitel01.wav' `
	-Language German
```

Ohne `OutputPath` wird `data/audiobooks/<Textdateiname>.wav` im Projektordner verwendet. Bestehende Ausgabedateien werden nicht ueberschrieben. Die Ausgabe ist eine zusammenhaengende PCM-16-WAV-Datei. MP3/M4B-Export und ein entsprechender Formatparameter sind bewusst nicht enthalten: PowerShell/.NET bietet keinen eingebauten MP3-Encoder; externe Tools, Clouddienste und zusaetzliche Pakete werden fuer diese Umwandlung nicht eingesetzt. FFmpeg oder Python auf dem Windows-Host sind nicht erforderlich.

Mehrere Kapiteldateien in einem Ordner lassen sich mit `Convert-QwenFolder.ps1` stapelweise verarbeiten. Das Skript verarbeitet die `.txt`-Dateien direkt im Quellordner alphabetisch; Unterordner werden nicht durchsucht. Sprache ist optional und standardmaessig `German`, der Zielordner ebenfalls optional:

```powershell
.\Convert-QwenFolder.ps1 `
	-VoiceFile '.\data\voices\Meine Stimme\Meine Stimme.pt' `
	-SourceDirectory 'C:\Buch\Kapitel' `
	-Language English `
	-OutputDirectory 'C:\Buch\Audio'
```

Ohne `OutputDirectory` gilt der Standardordner `data/audiobooks`. Pro Textdatei wird eine gleichnamige WAV-Datei erzeugt. Ein Fehler stoppt die weiteren Kapitel nicht; das Ergebnis enthaelt Anzahl und Status pro Datei.

Das Skript teilt an Absatz- und Satzgrenzen auf und erzeugt die Abschnitte nacheinander mit demselben Stimmprofil. Standard sind maximal **600 Zeichen pro Abschnitt**, keine feste Zahl von Saetzen. Lange Einzelsaetze werden bei Bedarf an Wortgrenzen geteilt; einzelne ueberlange Woerter notfalls innerhalb des Wortes. Satzgrenzen werden heuristisch erkannt; Abkuerzungen koennen zusaetzliche Grenzen erzeugen. Abschnitte verschiedener Absaetze werden nicht vermischt. Einfache Zeilenumbrueche gelten als Leerzeichen, Leerzeilen als Absatzgrenzen. PDF/EPUB-Import und Bereinigung von Silbentrennung sind nicht enthalten.

Weitere Optionen:

```powershell
.\Convert-QwenChapter.ps1 -TextPath '.\kapitel.txt' `
	-VoiceFile '.\data\voices\Meine Stimme\Meine Stimme.pt' `
	-MaxChars 500 -SentencePause 0.2 -ParagraphPause 0.6 `
	-QwenUrl 'http://localhost:8000' -TimeoutSec 1800 -Retries 1
```

`SentencePause` ist die zusaetzliche Pause zwischen Audioabschnitten desselben Absatzes, nicht nach jedem Satz innerhalb eines Abschnitts. `ParagraphPause` gilt zwischen Absaetzen; beide Angaben sind Sekunden. Vom Modell bereits erzeugte Stille wird nicht entfernt. `Retries` gibt die Zahl zusaetzlicher Versuche pro fehlgeschlagenem Abschnitt an. `TimeoutSec` gilt pro HTTP-Aufruf. Bei einem Timeout kann der serverseitige Auftrag noch weiterlaufen.

Neben der Ausgabe entsteht der Arbeitsordner `<Ausgabedatei>.work` mit `job.json`, nummerierten Textabschnitten und einzelnen WAV-Dateien. Nach einem Abbruch **denselben Aufruf wiederholen**: Fertige Abschnitte mit passender SHA-256-Pruefsumme werden nicht erneut erzeugt. Beschaedigte oder fehlende Abschnitte werden neu generiert. Aenderungen an Kapiteldatei, Stimmprofil, Sprache, API-Adresse oder Chunk-/Pauseneinstellungen werden erkannt und fuer denselben Arbeitsordner abgelehnt; fuer eine andere Fassung einen neuen `OutputPath` verwenden. Bei einer Fortsetzung muss hinter derselben API-Adresse weiterhin dasselbe Qwen-Modell laufen. Ein Dateilock verhindert parallele Laeufe im selben Arbeitsordner. Die WAV-Datei wird erst nach vollstaendiger Zusammenfuehrung veroeffentlicht.

`CleanUp` ist standardmaessig `$true`: Nach erfolgreich erzeugter Kapitel-WAV und Freigabe des Dateilocks wird der komplette `.work`-Ordner geloescht. Bei einem Fehler bleiben die Zwischenstaende unabhaengig von `CleanUp` zum Fortsetzen erhalten. Fuer eine spaetere Kontrolle der Einzelabschnitte den Arbeitsordner explizit behalten:

```powershell
.\Convert-QwenChapter.ps1 -TextPath '.\kapitel.txt' `
	-VoiceFile '.\data\voices\Meine Stimme\Meine Stimme.pt' -CleanUp:$false
```

Bei geloeschtem Arbeitsordner ist `WorkDirectory` im Ergebnisobjekt leer (`$null`). Mit `-CleanUp:$false` bleiben Zwischenstaende erhalten und belegen zusaetzlichen Speicher. Bei erneutem Aufruf mit bereits fertiger Ausgabedatei wird abgebrochen, nicht ueberschrieben. Klassisches RIFF-WAV ist auf knapp 4 GB Audiodaten pro Kapitel begrenzt.

Die Abschnittsgroesse ist keine Garantie gegen Modellfehler oder das Audio-Tokenlimit. Bei abgeschnittenen Passagen eine kleinere `MaxChars`-Einstellung und einen neuen Ausgabepfad verwenden. Es gibt keine automatische Vollstaendigkeitspruefung per STT und keine Lautheitsnormalisierung. Stimme, Betonung und Tempo koennen zwischen Abschnitten variieren; fuer ein Hoerbuch bleibt eine Hoerkontrolle erforderlich.

Tests ohne laufendes Modell:

```powershell
pwsh -File .\tests\Convert-QwenChapter.Tests.ps1
```

## Anderer Port oder anderes Modell

Das Startskript akzeptiert `-Model` und `-Port`. Ohne Parameter verwendet es `Qwen/Qwen3-TTS-12Hz-0.6B-Base` auf Port `8000`.

Alle zulaessigen Werte fuer `-Model`:

| Modell | Verwendung |
| --- | --- |
| `Qwen/Qwen3-TTS-12Hz-0.6B-Base` | Standard: eigene Stimme aus Referenzaudio; fuer beide Automatisierungsskripte geeignet |
| `Qwen/Qwen3-TTS-12Hz-1.7B-Base` | Eigene Stimme aus Referenzaudio; groesseres Modell, ebenfalls fuer beide Skripte geeignet |
| `Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice` | Vorgegebene Stimmen, keine eigenen Stimmprofile |
| `Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice` | Vorgegebene Stimmen und Steuerung der Sprechweise per Anweisung |
| `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign` | Stimme anhand einer Textbeschreibung erzeugen |

Beispiele:

```powershell
.\Start-Qwen3TTS.ps1 -Port 8001 -Model Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice
.\Start-Qwen3TTS.ps1 -Model Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign
.\Start-Qwen3TTS.ps1 -Model Qwen/Qwen3-TTS-12Hz-0.6B-Base
```

Ein Start mit einem anderen Modell ersetzt den laufenden Qwen-Dienst. Beim ersten Einsatz wird das betreffende Modell heruntergeladen; vorhandene Downloads bleiben im Cache. Die 1.7B-Modelle benoetigen mehr GPU-Speicher als die 0.6B-Modelle. Fuer `New-QwenVoice.ps1` und `Convert-QwenChapter.ps1` muss ein **Base**-Modell laufen; CustomVoice und VoiceDesign bieten die benoetigten Stimmprofil-APIs nicht an.

CustomVoice bietet vorgegebene Stimmen, VoiceDesign eine Stimme nach Beschreibung und Base Voice-Cloning mit Referenzaudio. Es laeuft jeweils ein Modell. Die Parameter bei jedem erneuten Start wieder angeben, sonst gelten die Standardwerte. Fuer Mikrofonzugriff direkt `localhost` verwenden; Browser behandeln localhost normalerweise als sicheren Kontext, obwohl HTTP verwendet wird.

## Lokale Daten und Netzwerk

Die persistenten Containerdaten liegen in Bind-Mounts relativ zu diesem Projektordner. Die Automatisierungsskripte speichern ihre Ergebnisse standardmaessig ebenfalls im Projektordner, direkt auf dem Host:

| Unterordner | Inhalt |
| --- | --- |
| `data/huggingface` | Heruntergeladene Modelle und Hugging-Face-Cache |
| `data/whisper` | Eigener Whisper-Modellcache, sonstiger Cache und temporaere Dateien |
| `data/gradio` | Gradio-Audiodateien und Upload-Cache |
| `data/tmp` | Temporaere Dateien, z.B. gespeicherte Stimm-Prompts |
| `data/voices` | Automatisch erstellte, benannte Stimmprofile und Transkripte auf dem Host |
| `data/audiobooks` | Standardausgabe der Kapitelverarbeitung inklusive Arbeitsordnern auf dem Host |

Die Containerordner werden beim Start angelegt, Skript-Ausgabeordner bei Bedarf. Webdateien sind kein dauerhaftes Archiv; wichtige Audios ueber den Browser herunterladen. Docker-Images und Build-Cache liegen weiterhin im normalen Docker-Desktop-Speicher, nicht unter `data`.

Veroeffentlicht werden ausschliesslich lokale Ports: Qwen auf `127.0.0.1:8000:8000` und der eigene Whisper auf `127.0.0.1:5001:5000` (bzw. die gewaehlten Host-Ports). Es gibt keine LAN-Portbindung und keinen oeffentlichen Gradio-Share-Link. Im Container muss die Anwendung auf `0.0.0.0` lauschen, damit die Docker-Portweiterleitung funktioniert. Andere Container im selben Docker-Netz koennen den jeweiligen Dienst ebenfalls erreichen; localhost-Bindung ist keine Isolation gegen lokale Prozesse oder Docker-Administratoren. Ausgehende Internetverbindungen fuer Downloads bleiben erlaubt.

Konfiguration ohne Containerstart anzeigen:

```powershell
.\Start-Qwen3TTS.ps1 -Action Config
```

Bei GPU-Problemen Docker Desktop/WSL2 und den NVIDIA-Windows-Treiber aktualisieren. Bei vollem VRAM das 0.6B-Modell verwenden. Bei belegtem Port mit `-Port 8001` starten.

Falls Docker nach einem CUDA-Absturz `tried to kill container, but did not receive an exit event` meldet, Docker Desktop bei Gelegenheit neu starten und danach das Startskript erneut ausfuehren. Ein Docker-Neustart unterbricht auch andere Container. Der erste lokale Test mit float16 loeste einen solchen CUDA-Absturz aus; die Konfiguration verwendet deshalb jetzt bfloat16. Mit dieser Konfiguration wurden Stimmprofilerstellung aus MP3 und die Vertonung zweier Absaetze inklusive WAV-Zusammenfuehrung erfolgreich getestet. Ein komplettes Hoerbuch wurde noch nicht getestet.

Quelle: <https://github.com/QwenLM/Qwen3-TTS>