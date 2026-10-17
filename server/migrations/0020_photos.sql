-- Profile photos for teachers and students. The column holds the stored
-- file's name (never a path); the file lives in PHOTOS_DIR. Null = no photo,
-- the app draws the first letter of the name instead.
alter table teachers add column photo text;
alter table students add column photo text;
