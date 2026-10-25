#
# PromptMaster backend
# (C) 2026 Daniel Boehringer
# TODO: RTF-output
#

#!/usr/bin/env perl
use utf8;
use Mojolicious::Lite;
use DBD::Pg qw(:pg_types);
use Mojo::Pg;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json to_json from_json);
use Mojo::File;
use Mojo::Util qw(xml_escape b64_encode);
use File::Temp qw(tempfile tempdir);
use File::Basename;
use POSIX qw(strftime);
use Encode qw(encode decode);
use Data::Dumper;


# =========================================================
# KONFIGURATION & DATENBANK
# =========================================================
helper pg => sub {
    state $pg = Mojo::Pg->new($ENV{DATABASE_URL} // 'postgresql://postgres:postgres@localhost/prompt_master');
    return $pg;
};

# Remote vLLM Konfiguration
my $vllm_endpoint   = $ENV{VLLM_ENDPOINT}   // 'https://inference-api.aipier.kn.uniklinik-freiburg.de/v1/chat/completions';
my $vllm_api_key    = $ENV{VLLM_API_KEY}    // 'ap-';
my $default_model   = $ENV{VLLM_MODEL}      // 'gpt-oss-120b';

# Lokale Ollama Konfiguration (OpenAI-kompatibler Endpunkt)
my $ollama_endpoint = $ENV{OLLAMA_ENDPOINT} // 'http://10.210.21.203:11434/v1/chat/completions';

# MinerU PDF-Parser (PDF -> Markdown inkl. OCR)
my $mineru_endpoint = $ENV{MINERU_ENDPOINT} // 'http://10.210.21.201:8008/file_parse';

# LaTeX-Assets (Briefköpfe, Logos ...) für pdflatex, Ordner neben backend.pl.
# Einmal beim Start absolut auflösen, damit es unabhängig vom Arbeitsverzeichnis ist.
my $latex_assets_dir = $ENV{LATEX_ASSETS_DIR} // app->home->child('latex_assets')->to_abs->to_string;
app->log->warn("LaTeX-Asset-Ordner '$latex_assets_dir' existiert nicht") unless -d $latex_assets_dir;

# Größere Uploads erlauben (Mojolicious-Default sind 16 MB)
app->hook(after_build_tx => sub {
          my ($tx, $app) = @_;
          $tx->req->max_message_size(200 * 1024 * 1024);
});

# UserAgent mit 3600 Sekunden (1 Stunde) Timeout
my $ua = Mojo::UserAgent->new(
                              request_timeout    => 3600,
                              inactivity_timeout => 3600,
                              connect_timeout    => 60
                              );

# Global CORS
app->hook(before_dispatch => sub {
          my $c = shift;
          $c->res->headers->header('Access-Control-Allow-Origin'  => '*');
          $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, OPTIONS');
          $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization');
          if ($c->req->method eq 'OPTIONS') {
          $c->render(text => '', status => 204);
          return;
          }
});

# =========================================================
# HELPER FÜR PDF FORMULARE (PDFTK & XFDF)
# =========================================================

sub extract_pdf_fields {
    my ($pdf_bytes) = @_;
    return [] unless $pdf_bytes;

    my $tempdir = tempdir(CLEANUP => 1);
    my $pdf_path = "$tempdir/temp_tpl.pdf";
    Mojo::File->new($pdf_path)->spurt($pdf_bytes);

    my $dump_output = `pdftk "$pdf_path" dump_data_fields_utf8 2>/dev/null`;
    return [] unless $dump_output;

    my @fields;
    my $current_field = {};

    for my $line (split /\r?\n/, $dump_output) {
        if ($line =~ /^---/) {
            if ($current_field->{FieldName}) {
                push @fields, { %$current_field };
            }
            $current_field = {};
        }
        elsif ($line =~ /^FieldType:\s*(.+)$/) {
            $current_field->{FieldType} = $1;
        }
        elsif ($line =~ /^FieldName:\s*(.+)$/) {
            $current_field->{FieldName} = $1;
        }
        elsif ($line =~ /^FieldFlags:\s*(.+)$/) {
            $current_field->{FieldFlags} = $1;
        }
        elsif ($line =~ /^FieldValue:\s*(.*)$/) {
            $current_field->{FieldValue} = $1;
        }
    }
    if ($current_field->{FieldName}) {
        push @fields, { %$current_field };
    }

    return \@fields;
}

sub generate_xfdf {
    my ($data_hash) = @_;
    my $xml = qq{<?xml version="1.0" encoding="UTF-8"?>\n};
    $xml .= qq{<xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">\n};
    $xml .= qq{  <fields>\n};

    for my $key (keys %$data_hash) {
        my $val = $data_hash->{$key} // '';
        if (ref($val)) {
            $val = eval { encode_json($val) } // "$val";
        }
        my $escaped_key = xml_escape($key);
        my $escaped_val = xml_escape("$val");

        $xml .= qq{    <field name="$escaped_key">\n};
        $xml .= qq{      <value>$escaped_val</value>\n};
        $xml .= qq{    </field>\n};
    }

    $xml .= qq{  </fields>\n};
    $xml .= qq{</xfdf>\n};
    return $xml;
}

# =========================================================
# HELPER FÜR MINERU (PDF -> MARKDOWN)
# =========================================================

sub extract_mineru_markdown {
    my ($res_data) = @_;
    my $text_content = '';

    # 1. Spezifischer Pfad für das MinerU-Format: results -> {document_key} -> md_content
    if (ref $res_data eq 'HASH' && ref $res_data->{results} eq 'HASH') {
        foreach my $file_key (keys %{ $res_data->{results} }) {
            my $file_obj = $res_data->{results}->{$file_key};
            if (ref $file_obj eq 'HASH' && defined $file_obj->{md_content}) {
                $text_content = $file_obj->{md_content};
                last;
            }
        }
    }

    # 2. Generische Fallback-Parser (falls MinerU ein anderes Format liefert)
    if (!$text_content || $text_content eq '') {
        if (ref $res_data eq 'ARRAY') {
            my $first = $res_data->[0];
            if (ref $first eq 'HASH') {
                $text_content = $first->{markdown} // $first->{md} // $first->{content} // '';
            }
        }
        elsif (ref $res_data eq 'HASH') {
            if (exists $res_data->{markdown}) {
                $text_content = $res_data->{markdown};
            }
            elsif (ref $res_data->{data} eq 'HASH' && exists $res_data->{data}->{markdown}) {
                $text_content = $res_data->{data}->{markdown};
            }
            elsif (ref $res_data->{result} eq 'HASH' && exists $res_data->{result}->{markdown}) {
                $text_content = $res_data->{result}->{markdown};
            }
            elsif (ref $res_data->{results} eq 'ARRAY') {
                my $first = $res_data->{results}->[0];
                if (ref $first eq 'HASH') {
                    $text_content = $first->{markdown} // $first->{md} // $first->{content} // '';
                }
            }
            else {
                foreach my $k (keys %$res_data) {
                    if ($k =~ /md|markdown|text|content/i && !ref $res_data->{$k}) {
                        $text_content = $res_data->{$k};
                        last;
                    }
                }
            }
        }
    }

    return $text_content // '';
}

# =========================================================
# HIERARCHIE TREE ROUTE
# =========================================================
get '/api/prompts/tree' => sub {
    my $c = shift;
    my $rows = eval {
        $c->pg->db->query(
            "SELECT id, parent_id, title, prompt_text, output_format, template_name, sort_order, is_expanded,
        (template_data IS NOT NULL) AS has_template
        FROM prompts
        ORDER BY parent_id NULLS FIRST, sort_order ASC, id ASC"
        )->hashes->to_array;
    };

    if ($@) {
        return $c->render(json => { error => "DB Query failed: $@" }, status => 500);
    }

    my %by_id;
    my @roots;

    for my $row (@$rows) {
        $row->{children} = [];
        $row->{is_expanded} = ($row->{is_expanded} && $row->{is_expanded} ne 'f') ? Mojo::JSON->true : Mojo::JSON->false;
        $by_id{$row->{id}} = $row;
    }

    for my $row (@$rows) {
        if (defined $row->{parent_id} && $by_id{$row->{parent_id}}) {
            push @{$by_id{$row->{parent_id}}->{children}}, $row;
        } else {
            push @roots, $row;
        }
    }

    $c->render(json => \@roots);
};

# =========================================================
# PROMPT CRUD ROUTEN
# =========================================================
get '/api/prompts/:id' => sub {
    my $c = shift;
    my $id = $c->param('id');
    my $row = $c->pg->db->query(
        "SELECT id, parent_id, title, prompt_text, output_format, template_name, sort_order, is_expanded,
    (template_data IS NOT NULL) AS has_template
    FROM prompts WHERE id = ?", $id
    )->hash;
    return $c->render(json => { error => 'Prompt not found' }, status => 404) unless $row;
    $row->{is_expanded} = ($row->{is_expanded} && $row->{is_expanded} ne 'f') ? Mojo::JSON->true : Mojo::JSON->false;
    $c->render(json => $row);
};

post '/api/prompts' => sub {
    my $c = shift;
    my $payload = $c->req->json // {};

    my $parent_id   = $payload->{parent_id};
    my $title       = $payload->{title} // 'Neuer Prompt';
    my $prompt      = $payload->{prompt_text} // '';
    my $format      = $payload->{output_format} // 'markdown';
    my $is_expanded = exists $payload->{is_expanded} ? ($payload->{is_expanded} ? 1 : 0) : 1;

    my $max_order = $c->pg->db->query(
    "SELECT COALESCE(MAX(sort_order), -1) + 1 AS next_order FROM prompts WHERE parent_id IS NOT DISTINCT FROM ?",
    $parent_id
    )->hash->{next_order};

    my $new_id = $c->pg->db->query(
        "INSERT INTO prompts (parent_id, title, prompt_text, output_format, sort_order, is_expanded) 
    VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
    $parent_id, $title, $prompt, $format, $max_order, $is_expanded
    )->hash->{id};

    $c->render(json => { id => $new_id, success => 1 });
};

put '/api/prompts/:id' => sub {
    my $c = shift;
    my $id = $c->param('id');
    my $payload = $c->req->json // {};

    my @fields;
    my @values;

    for my $k (qw(title prompt_text output_format parent_id sort_order is_expanded)) {
        if (exists $payload->{$k}) {
            push @fields, "$k = ?";
            if ($k eq 'is_expanded') {
                push @values, $payload->{$k} ? 1 : 0;
            } else {
                push @values, $payload->{$k};
            }
        }
    }

    if (@fields) {
        push @values, $id;
        my $sql = "UPDATE prompts SET " . join(", ", @fields) . ", updated_at = NOW() WHERE id = ?";
        $c->pg->db->query($sql, @values);
    }

    $c->render(json => { success => 1 });
};

del '/api/prompts/:id' => sub {
    my $c = shift;
    my $id = $c->param('id');
    $c->pg->db->query("DELETE FROM prompts WHERE id = ?", $id);
    $c->render(json => { success => 1 });
};

post '/api/prompts/reorder' => sub {
    my $c = shift;
    my $payload   = $c->req->json // {};
    my $node_id   = $payload->{id};
    my $parent_id = $payload->{parent_id};
    my $new_index = $payload->{index} // 0;

    return $c->render(json => { error => 'Missing id' }, status => 400) unless defined $node_id;

    my $db = $c->pg->db;
    my $tx = $db->begin;

    my $siblings = $db->query(
        "SELECT id FROM prompts 
    WHERE parent_id IS NOT DISTINCT FROM ?
    ORDER BY sort_order ASC, id ASC",
    $parent_id
    )->hashes->to_array;

    my @sibling_ids = map { $_->{id} } @$siblings;
    @sibling_ids = grep { $_ != $node_id } @sibling_ids;

    $new_index = 0 if $new_index < 0;
    $new_index = scalar(@sibling_ids) if $new_index > scalar(@sibling_ids);
    splice(@sibling_ids, $new_index, 0, $node_id);

    for my $order (0 .. $#sibling_ids) {
        $db->query(
        "UPDATE prompts SET parent_id = ?, sort_order = ? WHERE id = ?",
        $parent_id, $order, $sibling_ids[$order]
        );
    }

    $tx->commit;
    $c->render(json => { success => 1 });
};

# =========================================================
# TEMPLATE UPLOAD & DOWNLOAD ROUTEN
# =========================================================
post '/api/prompts/:id/upload_template' => sub {
    my $c = shift;
    my $id = $c->param('id');
    my $upload = $c->req->upload('file');

    return $c->render(json => { error => 'Keine Datei hochgeladen' }, status => 400) unless $upload;

    my $filename = $upload->filename;
    my $bytes    = $upload->slurp;

    $c->pg->db->query(
    "UPDATE prompts SET template_name = ?, template_data = ? WHERE id = ?",
    $filename,
    { type => PG_BYTEA, value => $bytes },
    $id
    );

    $c->render(json => { success => 1, template_name => $filename });
};

get '/api/prompts/:id/download_template' => sub {
    my $c = shift;
    my $id = $c->param('id');
    my $row = $c->pg->db->query("SELECT template_name, template_data FROM prompts WHERE id = ?", $id)->hash;

    return $c->render(text => 'Template not found', status => 404) unless $row && $row->{template_data};

    $c->res->headers->header('Content-Type' => 'application/pdf');
    $c->res->headers->header('Content-Disposition' => 'attachment; filename="' . ($row->{template_name} // 'template.pdf') . '"');
    $c->render(data => $row->{template_data});
};

# =========================================================
# PDF -> TEXT (MINERU) FÜR DAS EINGABEFELD
# =========================================================
post '/api/parse_pdf' => sub {
    my $c = shift;
    $c->inactivity_timeout(3600);

    my $upload = $c->req->upload('file');
    return $c->render(json => { success => 0, error => 'Keine Datei hochgeladen' }, status => 400) unless $upload;

    my $pdf_data = $upload->slurp;
    my $filename = $upload->filename // 'document.pdf';

    unless ($pdf_data && length($pdf_data) > 500) {
        return $c->render(json => { success => 0, error => 'PDF ist leer oder zu klein' }, status => 400);
    }

    $c->app->log->info(">>> [MINERU] Parse '$filename' (" . length($pdf_data) . " Bytes)");

    my $miner_ua = Mojo::UserAgent->new(
                                        request_timeout    => 900,
                                        inactivity_timeout => 900,
                                        connect_timeout    => 30
                                        );

    $c->render_later;

    $miner_ua->post_p($mineru_endpoint => form => {
        files     => { content => $pdf_data, filename => 'document.pdf', 'Content-Type' => 'application/pdf' },
        backend   => 'pipeline',
        return_md => 'true'
    })->then(sub {
        my $tx = shift;
        undef $miner_ua;

        unless ($tx->result && $tx->result->is_success) {
            my $err_msg = $tx->error ? $tx->error->{message} : 'HTTP Status ' . ($tx->res ? $tx->res->code : 'Unknown');
            die "MinerU-Anfrage fehlgeschlagen: $err_msg\n";
        }

        my $res_data = eval { decode_json($tx->result->body) };
        die "MinerU lieferte kein gültiges JSON\n" unless $res_data;

        my $text_content = extract_mineru_markdown($res_data);
        die "MinerU lieferte keinen Text zurück\n" unless length($text_content // '');

        $c->render(json => {
            success  => 1,
            filename => $filename,
            markdown => $text_content
        });
    })->catch(sub {
        my $err = shift;
        undef $miner_ua;
        $c->app->log->error(">>> [MINERU] $err");
        $c->render(json => { success => 0, error => "$err" }, status => 502);
    });
};

# =========================================================
# LLM EXECUTION ROUTE
# =========================================================
post '/api/prompts/run' => sub {
    my $c = shift;
    $c->inactivity_timeout(3600);

    my $payload    = $c->req->json // {};
    my $prompt_id  = $payload->{prompt_id};
    my $user_input = $payload->{input_text} // '';
    my $model      = $payload->{model} // $default_model;

    my $prompt_row = $c->pg->db->query("SELECT * FROM prompts WHERE id = ?", $prompt_id)->hash;
    return $c->render(json => { error => 'Prompt nicht gefunden' }, status => 404) unless $prompt_row;

    my $system_or_template = $prompt_row->{prompt_text} // '';
    my $output_format      = $prompt_row->{output_format} // 'markdown';

    my $final_prompt;
    if ($system_or_template =~ /\{INPUT\}/i) {
        ($final_prompt = $system_or_template) =~ s/\{INPUT\}/$user_input/g;
    } else {
        $final_prompt = $system_or_template . "\n\n" . $user_input;
    }

    my $tpl_bytes = $prompt_row->{template_data};
    if ($output_format eq 'pdf_fill') {
        if (!$tpl_bytes) {
            return $c->render(json => {
                type    => 'markdown',
                content => "⚠️ Kein PDF-Template für diesen Prompt hinterlegt. Bitte lade zuerst ein ausfüllbares PDF hoch."
            });
        }

        my $fields = extract_pdf_fields($tpl_bytes);
        if (!@$fields) {
            return $c->render(json => {
                type    => 'markdown',
                content => "⚠️ Im PDF wurden keine Formularfelder gefunden."
            });
        }

        my @field_names = map { $_->{FieldName} } @$fields;
        my $fields_list_str = join("\n", map { "- $_" } @field_names);

        $final_prompt = qq{Du bist ein Assistent zum automatischen Ausfüllen von PDF-Formularen.

            Im Folgenden sind die exakten Feldnamen des PDF-Formulars aufgeführt:
            $fields_list_str

            Aufgabe und Kontext:
            $final_prompt

            WICHTIGE ANWEISUNG:
            Antworte AUSSCHLIESSLICH mit einem validen JSON-Objekt, dessen Keys exakt den oben genannten Feldnamen entsprechen.
            Beispiel-Format:
            {
                "FieldName1": "Wert 1",
                "FieldName2": "Wert 2"
            }
            Gib KEINEN einleitenden Text und keine Erklärungen außerhalb des JSON-Objekts aus!};
    }
    elsif ($output_format eq 'latex') {
        # Bringt der Prompt eine eigene Vorlage mit (\documentclass), keine Standard-Präambel erzwingen
        my $preamble_hint = ($system_or_template =~ /\\documentclass/)
            ? "Verwende exakt die im Prompt vorgegebene LaTeX-Vorlage inklusive Präambel (Dokumentklasse, Pakete, Briefkopf) und ändere die Präambel nicht."
            : qq{Verwende:
            - \\documentclass[11pt,a4paper]{article}
            - \\usepackage[utf8]{inputenc}
            - \\usepackage[T1]{fontenc}
            - \\usepackage[ngerman]{babel}
            - \\usepackage[margin=2.5cm]{geometry}
            - \\usepackage{amsmath,amssymb,graphicx,hyperref,booktabs,microtype}};

        $final_prompt = qq{Du bist ein professioneller LaTeX-Setzer.
            Erstelle ein vollständiges, fehlerfrei kompilierbares LaTeX-Dokument basierend auf der folgenden Anweisung und dem Eingabetext.

            $preamble_hint

            WICHTIGE ANWEISUNG:
            Antworte AUSSCHLIESSLICH mit dem reinen LaTeX-Dokument (beginnend mit \\documentclass und endend mit \\end{document}).
            Gib KEINERLEI einleitenden Text, keine Markdown-Codeblöcke (kein ```latex) und keine Erklärungen vor oder nach dem Dokument aus!

            Aufgabe und Kontext:
            $final_prompt};
    }

    my $target_endpoint;
    my %headers = ('Content-Type' => 'application/json');

    if ($model =~ /mlx$/i) {
        $target_endpoint = $ollama_endpoint;
        $c->app->log->info(">>> [ROUTING] MLX Modell '$model' -> Route zu lokalem Ollama ($target_endpoint)");
    } else {
        $target_endpoint = $vllm_endpoint;
        $headers{'Authorization'} = "Bearer $vllm_api_key";
        $c->app->log->info(">>> [ROUTING] Standard-Modell '$model' -> Route zu vLLM ($target_endpoint)");
    }

    $c->render_later;

    my $req_body = {
        model       => $model,
        messages    => [
        { role => 'system', content => "Du bist ein präziser KI-Assistent. Befolge die Format-Anweisungen strikt." },
        { role => 'user',   content => $final_prompt }
        ],
        temperature => 0.1
    };

    $ua->post_p(
    $target_endpoint => \%headers => json => $req_body
    )->then(sub {
        my $tx = shift;
        unless ($tx->result && $tx->result->is_success) {
            my $err_msg = $tx->error ? $tx->error->{message} : 'HTTP Status ' . ($tx->res ? $tx->res->code : 'Unknown');
            die "LLM Request an $target_endpoint fehlgeschlagen: $err_msg";
        }

        my $content = $tx->result->json('/choices/0/message/content') // '';

        if ($output_format eq 'markdown') {
            return $c->render(json => {
                type    => 'markdown',
                content => $content
            });
        }
        elsif ($output_format eq 'latex') {
            my $latex_code = $content;

            if ($latex_code =~ /(\\documentclass[\s\S]*?\\end\{document\})/i) {
                $latex_code = $1;
            } else {
                $latex_code =~ s/^```(?:latex|tex)?\s*//gmi;
                $latex_code =~ s/\s*```$//gmi;
            }

            # Zeichen, die pdflatex mit inputenc nicht kennt (gpt-oss gibt sie gern aus)
            $latex_code =~ s/\x{202F}/\\,/g;                  # schmales geschütztes Leerzeichen
            $latex_code =~ s/\x{00A0}/~/g;                      # geschütztes Leerzeichen
            $latex_code =~ s/[\x{2011}\x{2010}]/-/g;           # geschützter Bindestrich / Bindestrich
            $latex_code =~ s/[\x{200B}\x{200C}\x{200D}\x{2060}\x{FEFF}\x{00AD}]//g;  # unsichtbare Zeichen

            # Nicht ersetzte Platzhalter <<...>> sichtbar als fehlend markieren
            $latex_code =~ s{<<\s*([^<>]+?)\s*>>}{ my $n = $1; $n =~ s/_/ /g; "\\textbf{[FEHLT: $n]}" }ge;

            my $tempdir  = tempdir(CLEANUP => 1);
            my $tex_path = "$tempdir/document.tex";
            my $pdf_path = "$tempdir/document.pdf";
            my $log_path = "$tempdir/document.log";

            Mojo::File->new($tex_path)->spurt(encode('UTF-8', $latex_code));

            {
                # Suchpfad: Asset-Ordner, Temp-Ordner, danach Standardpfade (abschließender Doppelpunkt)
                local $ENV{TEXINPUTS} = "$latex_assets_dir:$tempdir:";
                for (1 .. 2) {
                    system("pdflatex -no-shell-escape -interaction=nonstopmode -output-directory=\"$tempdir\" \"$tex_path\" > /dev/null 2>&1");
                }
            }

            if (-e $pdf_path && -s $pdf_path) {
                my $pdf_bytes = Mojo::File->new($pdf_path)->slurp;
                my $clean_title = $prompt_row->{title} // 'dokument';
                $clean_title =~ s/[^a-zA-Z0-9_\-\.]/_/g;
                my $download_name = "$clean_title.pdf";

                return $c->render(json => {
                    type        => 'download',
                    filename    => $download_name,
                    mime        => 'application/pdf',
                    base64_data => b64_encode($pdf_bytes, '')
                });
            } else {
                my $log_text = (-e $log_path) ? decode('UTF-8', Mojo::File->new($log_path)->slurp) : 'Keine Log-Datei generiert.';
                my @errors = grep { /^!/ } split /\r?\n/, $log_text;
                my $err_snippet = @errors ? join("\n", @errors[0 .. ($#errors > 5 ? 5 : $#errors)]) : 'pdflatex konnte kein PDF erzeugen.';

                return $c->render(json => {
                    type    => 'markdown',
                    content => "❌ **Fehler bei der LaTeX-Kompilierung:**\n\n"
                    . "```\n$err_snippet\n```\n\n"
                    . "### Generierter LaTeX-Code:\n```latex\n$latex_code\n```"
                });
            }
        }
        elsif ($output_format eq 'pdf_fill') {
            my $json_str = $content;
            $json_str =~ s/^```(?:json)?\s*//gmi;
            $json_str =~ s/\s*```$//gmi;

            my $form_data = eval { decode_json(encode('UTF-8', $json_str)) };

            if (!$form_data || ref($form_data) ne 'HASH') {
                return $c->render(json => {
                    type    => 'markdown',
                    content => "⚠️ Das Modell hat kein gültiges JSON für das PDF-Formular zurückgegeben:\n\n" . $content
                });
            }

            my $tempdir   = tempdir(CLEANUP => 1);
            my $tpl_path  = "$tempdir/template.pdf";
            my $xfdf_path = "$tempdir/data.xfdf";
            my $out_path  = "$tempdir/filled.pdf";

            Mojo::File->new($tpl_path)->spurt($tpl_bytes);
            my $xfdf_content = generate_xfdf($form_data);
            Mojo::File->new($xfdf_path)->spurt(encode('UTF-8', $xfdf_content));

            my $cmd_status = system("pdftk \"$tpl_path\" fill_form \"$xfdf_path\" output \"$out_path\" flatten");

            if ($cmd_status == 0 && -e $out_path) {
                my $final_pdf = Mojo::File->new($out_path)->slurp;
                my $out_name  = 'ausgefuellt_' . ($prompt_row->{template_name} // 'formular.pdf');

                return $c->render(json => {
                    type        => 'download',
                    filename    => $out_name,
                    mime        => 'application/pdf',
                    base64_data => b64_encode($final_pdf, '')
                });
            } else {
                return $c->render(json => {
                    type    => 'markdown',
                    content => "❌ Fehler beim Ausfüllen des PDF via pdftk. Rohdaten des LLMs:\n\n" . $content
                });
            }
        }
    })->catch(sub {
        my $err = shift;
        $c->render(json => { error => "$err" }, status => 500);
    });
};

app->config(hypnotoad => {
            listen             => ['http://*:4010'],
            workers            => 2,
            inactivity_timeout => 3600,
            heartbeat_timeout  => 3600
});

app->start;
