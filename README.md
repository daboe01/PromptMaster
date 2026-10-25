# ⚡ PromptMaster

**PromptMaster** ist eine spezialisierte Webanwendung zur Verwaltung, hierarchischen Strukturierung und Ausführung von LLM-Prompts für wissenschaftliche Studienprotokolle, Ethikanträge und Studienmanagement.

Die Anwendung kombiniert ein Desktop-artiges **Cappuccino-/Objective-J-Frontend** mit einem **Perl-Mojolicious-Backend**, **PDF-Formularbefüllung mit pdftk**, **LaTeX-Rendering mit pdflatex**, **PDF-Import über MinerU** und flexibler LLM-Anbindung (vLLM und lokales Ollama/MLX).

<img width="1273" height="857" alt="PromptMaster: Prompt-Bibliothek mit Editor" src="https://github.com/user-attachments/assets/4e09e5c4-3adb-4ee9-af47-767de4ab752e" />

---

## 🌟 Key Features

- **Hierarchische Prompt-Bibliothek**
  - Beliebig verschachtelbare Ordner- und Prompt-Struktur.
  - Reorganisation per **Drag & Drop** im `CPOutlineView`.
  - Speicherung inklusive Sortierreihenfolge und Auf-/Zuklapp-Zustand in PostgreSQL.
  - Upload von PDF-Vorlagen per Drag & Drop.

- **Eingabe aus PDF**
  - PDF-Dokumente (z. B. Studienprotokolle, Verträge) werden über **MinerU** in Markdown umgewandelt, inklusive OCR, und als Eingabetext übernommen.

- **Platzhalter `{INPUT}`**
  - `{INPUT}` im Prompttext wird durch den Eingabetext ersetzt. Fehlt der Platzhalter, wird der Eingabetext an den Prompt angehängt.

- **Drei Ausgabeformate**
  - **Markdown:** Ergebnis-Popover mit Umschaltung zwischen gerendertem Rich-Text (inkl. Tabellen, Fettdruck, Listen) und Roh-Markdown, mit Kopierfunktion.
  - **PDF via LaTeX:** Das LLM erzeugt ein LaTeX-Dokument, das serverseitig mit `pdflatex` kompiliert und als PDF heruntergeladen wird. Briefköpfe und Logos können im Ordner `latex_assets/` abgelegt werden. Nicht ersetzte Platzhalter `<<…>>` werden im PDF als **[FEHLT: …]** markiert.
  - **Automatisches Ausfüllen von PDF-Formularen:** Die Feldnamen der hinterlegten Vorlage werden ausgelesen, das LLM liefert die Werte, `pdftk` füllt das Formular aus. Ideal für die einheitlichen Formulare der Ethik-Kommission.

- **Duales LLM-Routing**
  - Standardmodelle (Default: `gpt-oss-120b`) werden an einen OpenAI-kompatiblen Endpunkt geroutet (z. B. vLLM).
  - Modelle, deren Name auf `mlx` endet, werden automatisch an eine lokale Ollama-Instanz weitergeleitet (z. B. auf Apple Silicon).

---

## 📋 Anwendungsbeispiel: Ethikantrag / Strukturierte Synopse

1. **Prompt auswählen:** Wähle in der Seitenleiste z. B. *„Strukturierte Synopse aus Freitext“* (Ausgabeformat: PDF-Formular ausfüllen).
2. **Vorlage hinterlegen:** Lade das offizielle PDF-Formular der Ethik-Kommission (z. B. `7-Strukturierte-Synopse.pdf`) per Drag & Drop auf den Upload-Button hoch.
3. **Eingabetext einfügen:** Wechsle in den Reiter **„Anwenden“** und füge dein Studienprotokoll oder deine Freitext-Notizen ein, oder importiere ein PDF.
4. **Ausführen:** Klicke auf **„⚡ Prompt durch LLM ausführen“**.
5. **Ergebnis:**
   - Bei **Markdown** öffnet sich das Popover mit gerendertem Rich-Text und Kopierfunktion.
   - Bei **PDF via LaTeX** wird das fertige PDF automatisch heruntergeladen.
   - Beim **Ausfüllen von PDF-Formularen** wird die hinterlegte Vorlage ausgefüllt heruntergeladen.

---

## 🚀 Schnellstart mit Docker Compose

### 1. Repository klonen

```bash
git clone https://github.com/daboe01/promptmaster.git
cd promptmaster
```

### 2. Konfiguration anpassen (optional)

Erstelle bei Bedarf eine `.env`-Datei im Hauptverzeichnis:

```env
# Datenbank
DATABASE_URL=postgresql://postgres:postgres@db/prompt_master

# Standard-LLM (OpenAI-kompatibel, z. B. vLLM)
VLLM_ENDPOINT=https://inference-api.aipier.kn.uniklinik-freiburg.de/v1/chat/completions
VLLM_API_KEY=dein_api_key_hier
VLLM_MODEL=gpt-oss-120b

# Lokale Modelle (*mlx) über Ollama
OLLAMA_ENDPOINT=http://host.docker.internal:11434/v1/chat/completions

# PDF-Import über MinerU
MINERU_ENDPOINT=http://mineru:8008/file_parse

# Ordner mit Briefköpfen/Logos für LaTeX (Default: latex_assets/ neben dem Backend)
LATEX_ASSETS_DIR=/app/latex_assets
```

| Variable | Zweck | Default im Backend |
|---|---|---|
| `DATABASE_URL` | PostgreSQL-Verbindung | `postgresql://postgres:postgres@localhost/prompt_master` |
| `VLLM_ENDPOINT` | Endpunkt für Standardmodelle | Inferenz-API Uniklinik Freiburg |
| `VLLM_API_KEY` | API-Key für den vLLM-Endpunkt | – (muss gesetzt werden) |
| `VLLM_MODEL` | Standardmodell | `gpt-oss-120b` |
| `OLLAMA_ENDPOINT` | Endpunkt für Modelle mit Namensendung `mlx` | interne Adresse |
| `MINERU_ENDPOINT` | MinerU-Dienst für den PDF-Import | interne Adresse |
| `LATEX_ASSETS_DIR` | Suchpfad für Grafiken in LaTeX-Dokumenten | `latex_assets/` |

### 3. Container starten

```bash
docker compose up --build -d
```

### 4. Anwendung aufrufen

Öffne im Browser `http://localhost:3001/Frontend/index.html`.

---

## 🛠️ Betrieb ohne Docker

Voraussetzungen: Perl mit `Mojolicious` und `Mojo::Pg`, PostgreSQL, `pdftk` und eine TeX-Distribution mit `pdflatex`.

```bash
hypnotoad app.pl      # startet auf Port 4010, erneuter Aufruf = Hot-Reload
```

---

## 📄 Lizenz

Dieses Projekt ist unter der **GNU Lesser General Public License v2.1 (LGPL-2.1)** lizenziert, siehe [`LICENSE`](LICENSE).

---

## 👨‍🔬 Autor

Entwickelt von **Prof. Dr. Daniel Böhringer**
Klinik für Augenheilkunde, Universitätsklinikum Freiburg.
