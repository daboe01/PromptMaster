FROM debian:bookworm-slim

# Umgebungsvariablen
ENV DEBIAN_FRONTEND=noninteractive
ENV PERL_CPANM_OPT="--notest --no-man-pages"

# 1. Systempakete, Build-Tools, pdftk und TeX Live (LaTeX) installieren
RUN apt-get update && apt-get install -y --no-install-recommends \
    perl \
    cpanminus \
    build-essential \
    libpq-dev \
    postgresql-client \
    pdftk-java \
    texlive-latex-base \
    texlive-latex-recommended \
    texlive-latex-extra \
    texlive-fonts-recommended \
    ca-certificates \
    curl \
    && ln -s /usr/bin/pdftk-java /usr/local/bin/pdftk || true \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 2. Perl-Abhängigkeiten installieren
RUN cpanm \
    Mojolicious \
    DBD::Pg \
    Mojo::Pg

# 3. Arbeitsverzeichnis einrichten
WORKDIR /app

# 4. Quellcode kopieren
COPY . /app

# Port freigeben (Hypnotoad / Backend Port 4010)
EXPOSE 4010

# Server via Hypnotoad starten (oder im Foreground via hypnotoad -f)
CMD ["hypnotoad", "-f", "app.pl"]