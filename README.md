# ⚡ PromptMaster

**PromptMaster** ist eine spezialisierte Webanwendung zur Verwaltung, hierarchischen Strukturierung und Ausführung von LLM-Prompts für wissenschaftliche Studienprotokolle, Ethikanträge und medizinische Dokumentationen.

Die Anwendung kombiniert ein Desktop-artiges **Cappuccino / Objective-J Frontend** mit einem **Perl Mojolicious Backend**, nativer **PDFtk-Formularbefüllung**, **LaTeX-Rendering** und flexibler LLM-Anbindung (vLLM & lokales Ollama/MLX).

---

## 🌟 Key Features

- **Hierarchische Prompt-Bibliothek:**
  - Beliebig verschachtelbare Ordner- und Prompt-Struktur.
  - Reorganisation via **Drag & Drop** im `CPOutlineView`.
  - Persistierung und automatische Sortierordnung in PostgreSQL.
  - Native Drag & Drop Uploads für PDF-Templates.

- **Multi-Format-Ausgabe:**
  - **Markdown & Rich-Text:** Ergebnis-Popover mit Reiter-Umschaltung zwischen gerendertem Rich-Text (inkl. Tabellen, Fettung, Listen) und Roh-Markdown.
  - **LaTeX zu PDF:** Direkte Übersetzung von LaTeX-Code in fertige PDF-Dokumente via `pdflatex`.
  - **Autmatisches Ausfüllen von PDF-Formularen:** Ideal für die einheitlichen Formulare der Ethikkommission.

- **Duales LLM-Routing:**
  - Standard-Modelle werden über externe Hochleistungs-Endpunkte geroutet (z. B. vLLM).
  - Lokale Apple-Silicon-/MLX-Modelle (`*mlx`) werden automatisch an eine lokale Ollama-Instanz weitergeleitet.

---

## 🏗 Architektur & Tech-Stack

```text
┌─────────────────────────────────────────────────────────────┐
│                    Browser Client                           │
│  Cappuccino Framework (Objective-J) + Renaissance Markup    │
│  - CPMarkdownParser / CPAttributedString / TableAttachment  │
│  - Drag & Drop TreeController                               │
└──────────────────────────────┬──────────────────────────────┘
                               │ HTTP / JSON
┌──────────────────────────────▼──────────────────────────────┐
│                  Backend (Docker Container)                 │
│  Perl (Mojolicious::Lite / Mojo::Pg / Hypnotoad)            │
│  ├── PDFtk (XFDF Form-Filling & Field Dumps)                │
│  └── TeX Live (pdflatex Compiler)                           │
└──────────────┬──────────────────────────────┬───────────────┘
               │                              │
┌──────────────▼──────────────┐┌──────────────▼───────────────┐
│     PostgreSQL 16 (DB)      ││   LLM Endpunkte (vLLM/Ollama)│
│  - prompts Tabelle          ││   - Remote vLLM (Cloud/GPU)  │
│  - Bytea PDF Templates      ││   - host.docker.internal (MLX)│
└─────────────────────────────┘└──────────────────────────────┘
```

- **Frontend:** Cappuccino (Objective-J), Renaissance Markup (`gui.gsmarkup`), native Web-Components.
- **Backend:** Perl 5, Mojolicious, `Mojo::Pg`, `DBD::Pg`.
- **System-Tools:** PDFtk-Java, TeX Live (`pdflatex`).
- **Datenbank:** PostgreSQL 16.

---

## 🚀 Schnellstart mit Docker Compose

### 1. Repository klonen

```bash
git clone https://github.com/DEIN_NUTZERNAME/promptmaster.git
cd promptmaster
```

### 2. Konfiguration anpassen (Optional)

Erstelle bei Bedarf eine `.env`-Datei im Hauptverzeichnis:

```env
VLLM_ENDPOINT=https://inference-api.aipier.kn.uniklinik-freiburg.de/v1/chat/completions
VLLM_API_KEY=dein_api_key_hier
VLLM_MODEL=gpt-oss-120b
OLLAMA_ENDPOINT=http://host.docker.internal:11434/v1/chat/completions
```

### 3. Container starten

```bash
docker compose up --build -d
```

### 4. Anwendung aufrufen

- **Frontend:** Öffne im Browser `http://localhost:3001/Frontend/index.html` (bzw. über deinen Webserver).
- **Backend API:** Erreichbar unter `http://localhost:4010/api/prompts/tree`.

---

## 📋 Anwendungsbeispiel: Ethikantrag / Strukturierte Synopse

1. **Prompt auswählen:** Wähle in der Seitenleiste z. B. *„Strukturierte Synopse aus Freitext“*.
2. **Template hinterlegen:** Lade das offizielle PDF-Formular der Ethikkommission (z. B. `7-Strukturierte-Synopse.pdf`) per Drag & Drop auf den Upload-Button hoch.
3. **Eingabetext einfügen:** Wechsle in den Reiter **„Anwenden“** und füge dein Studienprotokoll oder Freitext-Notizen ein.
4. **Ausführen:** Klicke auf **„⚡ Prompt durch LLM ausführen“**.
5. **Ergebnis:**
   - Bei **PDF-Ausfüll-Tool**: Das fertige, validierte PDF wird automatisch heruntergeladen.
   - Bei **Markdown**: Das Popover öffnet sich mit sauber gerendertem Rich-Text und Zwischenablage-Funktion.

---

## 🛠 Manuelle Entwicklungsumgebung (ohne Docker)

### Systemvoraussetzungen (macOS / Linux)

- Perl 5.30+
- PostgreSQL 14+
- PDFtk (`pdftk-java` oder native Binary)
- TeX Live (`pdflatex`)

### Perl-Abhängigkeiten installieren

```bash
cpanm Mojolicious DBD::Pg Mojo::Pg
```

### Datenbank vorbereiten

```bash
createdb prompt_master
psql -d prompt_master -f init.sql
```

### Backend starten

```bash
# Entwicklungsmodus
morbo app.pl

# Oder Produktionsserver
hypnotoad app.pl
```

---

## 📂 Projektstruktur

```text
├── app.pl                    # Mojolicious Backend & LLM-Routing
├── Dockerfile                # Docker Image Definition (Perl + PDFtk + LaTeX)
├── docker-compose.yml        # Multi-Container Setup (App + PostgreSQL)
├── init.sql                  # Datenbank-Initialisierungsschema
├── Frontend/
│   ├── index.html            # Cappuccino Einstiegspunkt
│   ├── AppController.j       # Hauptcontroller & UI-Logik (Objective-J)
│   ├── CPMarkdownParser.j    # Markdown zu CPAttributedString Parser
│   ├── RTFParser.j           # RTF Parser für Rich-Text
│   ├── _CPTableTextAttachment.j # Tabellen-Rendering Attachment
│   ├── gui.gsmarkup          # Renaissance UI Layout
│   └── model.gsmarkup        # Datenmodell-Bindings
└── README.md
```

---

## 📄 Lizenz

Dieses Projekt ist unter der **GNU Lesser General Public License v2.1 (LGPL-2.1)** lizenziert – siehe die entsprechenden Header in den Quelldateien.

---

## 👨‍🔬 Autoren & Danksagung

Entwickelt von **Prof. Dr. Daniel Böhringer**  
Klinik für Augenheilkunde, Universitätsklinikum Freiburg.
