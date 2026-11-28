-- TMDB episodes before the source's first one, when TMDB lists two broadcast seasons as one.
ALTER TABLE matches ADD COLUMN episode_offset INTEGER NOT NULL DEFAULT 0;
