CREATE TABLE IF NOT EXISTS prompts (
    id SERIAL PRIMARY KEY,
    parent_id INTEGER REFERENCES prompts(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    prompt_text TEXT DEFAULT '',
    output_format TEXT DEFAULT 'markdown',
    template_name TEXT,
    template_data BYTEA,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Index für hierarchische Abfragen
CREATE INDEX IF NOT EXISTS idx_prompts_parent_id ON prompts(parent_id);