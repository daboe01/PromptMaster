# AI-Powered Writing Assistant

A web-based, desktop-class text editor and proofreading suite. The application analyzes narrative text paragraph-by-paragraph, highlights errors (spelling, grammar, clarity, and style) with visual overlays, and allows users to apply suggested corrections with a single click.

This project is built as a **serverless, browser-only application**—eliminating the need for a custom server-side backend. The application runs entirely in the client's browser, communicating directly with LLM providers while storing API keys and configuration state securely in local browser storage.

---
<img width="1011" height="837" alt="Bildschirmfoto 2026-05-23 um 19 35 44" src="https://github.com/user-attachments/assets/57864753-bbd3-4ac8-8c76-0979b2eb6f8b" />

## Key Features

*   **Serverless / Frontend-Only Architecture**: Zero server-side installation required. Accessible directly via standard web hosting (such as GitHub Pages).
*   **Flexible LLM Integrations**: Connect seamlessly to various model providers directly from the UI:
    *   **Ollama**: Local execution for complete privacy.
    *   **Groq API**: High-speed cloud-based inference.
    *   **Google Gemini**: Highly-capable reasoning models.
    *   **OpenRouter**: Access to a vast range of open and closed-source models (with `google/gemini-2.0-flash-001` configured as the standard out-of-the-box model).
*   **Multilingual Analysis**: Built-in, client-side system prompts for German, English, and French analysis.
*   **Context-Aware Highlighting**: Highlights text segments based on four distinct categories:
    *   🔴 **Spelling**: Typos and spelling mistakes.
    *   🔵 **Grammar**: Syntax issues, tense inconsistencies, and punctuation.
    *   🟢 **Clarity**: Passive voice, overly wordy sentences, or confusing phrasing.
    *   🟣 **Style**: Tone improvements and formal adjustments.
*   **Client-Side Text Alignment**: Exact offset and length calculations are computed dynamically in the browser, matching LLM recommendations against the document text.
*   **Dynamic Range Shifting**: Applying a correction automatically recalculates and shifts the offsets of all remaining alerts in the paragraph, preventing highlight misalignment during active editing.

---

## Architecture Overview

```text
 ┌────────────────────────┐         Direct HTTPS Fetch (CORS)      ┌─────────────────────────┐
 │                        │  ───────────────────────────────────>  │   External LLM APIs     │
 │  Cappuccino Frontend   │                                        │  • Ollama (Localhost)   │
 │     (Objective-J)      │  <───────────────────────────────────  │  • Groq API             │
 │                        │        Raw JSON Response Objects       │  • Google Gemini        │
 │  Runs fully in browser │                                        │  • OpenRouter           │
 └───────────┬────────────┘                                        └─────────────────────────┘
             │
             │ Persistent Storage (State & Keys)
             ▼
 ┌────────────────────────┐
 │     Browser Storage    │
 │   (CPUserDefaults /    │
 │     LocalStorage)      │
 └────────────────────────┘
```

---

## Tech Stack

*   **Frontend UI & Engine**: Objective-J, Cappuccino SDK (AppKit & Foundation ports for the web)
*   **State Management**: `CPUserDefaults` (Browser LocalStorage wrapper)
*   **Inference Layer**: Native JavaScript `fetch` calling REST endpoints asynchronously

---

## Getting Started

### Prerequisites

*   A modern web browser (Safari, Chrome, Firefox, Edge).
*   **For local AI models (Ollama)**: Ensure Ollama is running locally with CORS enabled to allow browser requests:
    ```bash
    OLLAMA_ORIGINS="*" ollama serve
    ```
*   **For Cloud APIs (Groq, Gemini, OpenRouter)**: An active API key from the respective provider.

### Setup and Running Locally

1.  **Clone the repository**:
    ```bash
    git clone https://github.com/daboe01/GrammarMom2.git
    cd GrammarMom2
    ```

2.  **Start a local static server**:
    Since this is a fully static client-side application, you can run it using any simple web server. For example, using Python:
    ```bash
    python3 -m http.server 8000
    ```

3.  **Open the application**:
    Navigate to `http://localhost:8000` (or `http://localhost:8000/index.html`) in your browser.

---

## Deploying to GitHub Pages

Because the app is entirely static, deployment is straightforward:

1.  Go to your repository on GitHub.
2.  Navigate to **Settings** -> **Pages** (in the left-hand sidebar under *Code and automation*).
3.  Under **Build and deployment**, set **Source** to **Deploy from a branch**.
4.  Choose your main branch (e.g., `main`) and `/ (root)` folder, then click **Save**.
5.  Your writing assistant will be live in a couple of minutes at `https://<your-username>.github.io/GrammarMom2/`.

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
