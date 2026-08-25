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
  - **PDF-Ausfüll-Tool:** Formularbefüllung für offizielle Antragsformulare (z. B. Ethikkommission).

- **Duales LLM-Routing:**
  - Standard-Modelle werden über externe Hochleistungs-Endpunkte geroutet (z. B. vLLM).
  - Lokale Apple-Silicon-/MLX-Modelle (`*mlx`) werden automatisch an eine lokale Ollama-Instanz weitergeleitet.

---

## 🏗 Architektur & Tech-Stack