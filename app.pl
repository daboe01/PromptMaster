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
my $vllm_api_key    = $ENV{VLLM_API_KEY}    // 'ap-yf';
my $default_model   = $ENV{VLLM_MODEL}      // 'gpt-oss-120b';

# Lokale Ollama Konfiguration (OpenAI-kompatibler Endpunkt)
my $ollama_endpoint = $ENV{OLLAMA_ENDPOINT} // 'http://localhost:11434/v1/chat/completions';

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
# HIERARCHIE TREE ROUTE
# =========================================================
get '/api/prompts/tree' => sub {
    my $c = shift;
    my $rows = eval {
        $c->pg->db->query(
             "SELECT id, parent_id, title, prompt_text, output_format, template_name, sort_order, 
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
         "SELECT id, parent_id, title, prompt_text, output_format, template_name, sort_order,
    (template_data IS NOT NULL) AS has_template
    FROM prompts WHERE id = ?", $id
    )->hash;
    return $c->render(json => { error => 'Prompt not found' }, status => 404) unless $row;
    $c->render(json => $row);
};

post '/api/prompts' => sub {
    my $c = shift;
    my $payload = $c->req->json // {};

    my $parent_id = $payload->{parent_id};
    my $title     = $payload->{title} // 'Neuer Prompt';
    my $prompt    = $payload->{prompt_text} // '';
    my $format    = $payload->{output_format} // 'markdown';

    my $max_order = $c->pg->db->query(
    "SELECT COALESCE(MAX(sort_order), -1) + 1 AS next_order FROM prompts WHERE parent_id IS NOT DISTINCT FROM ?",
    $parent_id
    )->hash->{next_order};

    my $new_id = $c->pg->db->query(
         "INSERT INTO prompts (parent_id, title, prompt_text, output_format, sort_order) 
    VALUES (?, ?, ?, ?, ?) RETURNING id",
    $parent_id, $title, $prompt, $format, $max_order
    )->hash->{id};

    $c->render(json => { id => $new_id, success => 1 });
};

put '/api/prompts/:id' => sub {
    my $c = shift;
    my $id = $c->param('id');
    my $payload = $c->req->json // {};

    my @fields;
    my @values;

    for my $k (qw(title prompt_text output_format parent_id sort_order)) {
        if (exists $payload->{$k}) {
            push @fields, "$k = ?";
            push @values, $payload->{$k};
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
    my $payload = $c->req->json // {};
    my $node_id   = $payload->{id};
    my $parent_id = $payload->{parent_id};
    my $new_index = $payload->{index} // 0;

    my $tx = $c->pg->db->begin;
    $c->pg->db->query("UPDATE prompts SET parent_id = ?, sort_order = ? WHERE id = ?", $parent_id, $new_index, $node_id);
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
# LLM EXECUTION ROUTE (MIT OLLAMA LOCALHOST / MLX SUPPORT & LATEX)
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

    # Basis-Prompt aufbauen
    my $final_prompt;
    if ($system_or_template =~ /\{INPUT\}/i) {
        ($final_prompt = $system_or_template) =~ s/\{INPUT\}/$user_input/g;
    } else {
        $final_prompt = $system_or_template . "\n\n" . $user_input;
    }

    # ---------------------------------------------------------
    # PDF_FILL: Felder auslesen & in den Prompt injizieren
    # ---------------------------------------------------------
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
    # ---------------------------------------------------------
    # LATEX: System-Anweisung für vollständigen LaTeX-Code
    # ---------------------------------------------------------
    elsif ($output_format eq 'latex') {
        $final_prompt = qq{Du bist ein professioneller LaTeX-Setzer.
            Erstelle ein vollständiges, fehlerfrei kompilierbares LaTeX-Dokument basierend auf der folgenden Anweisung und dem Eingabetext.

        Verwende:
            - \\documentclass[11pt,a4paper]{article}
            - \\usepackage[utf8]{inputenc}
            - \\usepackage[T1]{fontenc}
            - \\usepackage[ngerman]{babel}
            - \\usepackage[margin=2.5cm]{geometry}
            - \\usepackage{amsmath,amssymb,graphicx,hyperref,booktabs,microtype}

            WICHTIGE ANWEISUNG:
            Antworte AUSSCHLIESSLICH mit dem reinen LaTeX-Dokument (beginnend mit \\documentclass und endend mit \\end{document}).
            Gib KEINERLEI einleitenden Text, keine Markdown-Codeblöcke (kein ```latex) und keine Erklärungen vor oder nach dem Dokument aus!

            Aufgabe und Kontext:
            $final_prompt};
    }

    # =========================================================
    # ENDPUNKT-ROUTING (MLX -> Localhost Ollama / Sonst vLLM)
    # =========================================================
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

        # ---------------------------------------------------------
        # FORMAT: MARKDOWN
        # ---------------------------------------------------------
        if ($output_format eq 'markdown') {
            return $c->render(json => {
                type    => 'markdown',
                content => $content
            });
        }
        # ---------------------------------------------------------
        # FORMAT: LATEX -> PDF KOMPILIERUNG
        # ---------------------------------------------------------
        elsif ($output_format eq 'latex') {
            my $latex_code = $content;

            # 1. LaTeX-Dokumentbereich isolieren (falls LLM doch Markdown drumherum gelegt hat)
            if ($latex_code =~ /(\\documentclass[\s\S]*?\\end\{document\})/i) {
                $latex_code = $1;
            } else {
                $latex_code =~ s/^```(?:latex|tex)?\s*//gmi;
                $latex_code =~ s/\s*```$//gmi;
            }

            my $tempdir  = tempdir(CLEANUP => 1);
            my $tex_path = "$tempdir/document.tex";
            my $pdf_path = "$tempdir/document.pdf";
            my $log_path = "$tempdir/document.log";

            Mojo::File->new($tex_path)->spurt(encode('UTF-8', $latex_code));

            # 2. pdflatex 2-mal im Nonstop-Modus ausführen (für Layout/Seitenumbrüche)
            system("pdflatex -interaction=nonstopmode -output-directory=\"$tempdir\" \"$tex_path\" > /dev/null 2>&1");
            system("pdflatex -interaction=nonstopmode -output-directory=\"$tempdir\" \"$tex_path\" > /dev/null 2>&1");

            # 3. PDF erfolgreich erzeugt -> Base64-Download zurückliefern
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
            }
            # 4. Fehler bei Kompilierung -> Fehlerdiagnose aus Log extrahieren & anzeigen
            else {
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
        # ---------------------------------------------------------
        # FORMAT: PDF_FILL (FORMULAR)
        # ---------------------------------------------------------
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
