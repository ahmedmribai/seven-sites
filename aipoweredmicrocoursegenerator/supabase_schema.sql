CREATE TABLE courses (
  id SERIAL PRIMARY KEY,
  topic TEXT NOT NULL,
  description TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);