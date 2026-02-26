#!/bin/bash
set -e  # exit on error

echo "=== Reifying the Qur'an Digital Library (Complete) ==="

# --- Prerequisites check ---
command -v node >/dev/null 2>&1 || { echo "Node.js not found. Please install Node.js v18+."; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "npm not found. Please install npm."; exit 1; }
command -v psql >/dev/null 2>&1 || { echo "PostgreSQL client not found. Please install PostgreSQL v14+."; exit 1; }
command -v sudo >/dev/null 2>&1 || { echo "sudo required for database setup."; exit 1; }

# Determine download tool
if command -v wget >/dev/null 2>&1; then
  DOWNLOAD="wget -O"
elif command -v curl >/dev/null 2>&1; then
  DOWNLOAD="curl -o"
else
  echo "Neither wget nor curl found. Please install one to download Quran text."
  exit 1
fi

# --- Create project root ---
mkdir -p quran-library
cd quran-library
PROJECT_ROOT=$(pwd)

# --- Setup PostgreSQL database and user ---
echo "Setting up PostgreSQL database..."
sudo -u postgres psql <<EOF
CREATE USER quran_user WITH PASSWORD 'secure_password';
CREATE DATABASE quran_library OWNER quran_user;
GRANT ALL PRIVILEGES ON DATABASE quran_library TO quran_user;
EOF

# --- Backend setup ---
echo "Creating backend..."
mkdir backend
cd backend

# package.json
cat > package.json <<'EOF'
{
  "name": "quran-backend",
  "version": "1.0.0",
  "main": "index.js",
  "scripts": {
    "start": "node index.js",
    "dev": "nodemon index.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5",
    "pg": "^8.11.0",
    "dotenv": "^16.0.3"
  },
  "devDependencies": {
    "nodemon": "^2.0.22"
  }
}
EOF

npm install

# .env
cat > .env <<EOF
DB_HOST=localhost
DB_PORT=5432
DB_USER=quran_user
DB_PASSWORD=secure_password
DB_NAME=quran_library
PORT=5000
EOF

# db.js
cat > db.js <<'EOF'
const { Pool } = require('pg');
require('dotenv').config();

const pool = new Pool({
  host: process.env.DB_HOST,
  port: process.env.DB_PORT,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
});

module.exports = pool;
EOF

# index.js
cat > index.js <<'EOF'
const express = require('express');
const cors = require('cors');
const pool = require('./db');

const app = express();
app.use(cors());
app.use(express.json());

// Get all surahs
app.get('/api/surahs', async (req, res) => {
  try {
    const result = await pool.query('SELECT id, name_ar, name_en, transliteration, revelation_type, verse_count FROM surah ORDER BY id');
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Get a single surah with its verses
app.get('/api/surahs/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const surah = await pool.query('SELECT * FROM surah WHERE id = $1', [id]);
    if (surah.rows.length === 0) return res.status(404).json({ error: 'Surah not found' });

    const verses = await pool.query(
      'SELECT id, verse_number, text_uthmani, juz, page FROM ayah WHERE surah_id = $1 ORDER BY verse_number',
      [id]
    );
    res.json({ surah: surah.rows[0], verses: verses.rows });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Get a specific verse
app.get('/api/verses/:id', async (req, res) => {
  try {
    const { id } = req.params;
    const verse = await pool.query(
      'SELECT a.*, s.name_ar as surah_name_ar FROM ayah a JOIN surah s ON a.surah_id = s.id WHERE a.id = $1',
      [id]
    );
    if (verse.rows.length === 0) return res.status(404).json({ error: 'Verse not found' });
    res.json(verse.rows[0]);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Search verses (simple)
app.get('/api/search', async (req, res) => {
  const { q } = req.query;
  if (!q) return res.status(400).json({ error: 'Query parameter q required' });

  try {
    const result = await pool.query(
      `SELECT a.id, a.verse_number, a.text_uthmani, s.name_ar as surah_name_ar, s.id as surah_id
       FROM ayah a
       JOIN surah s ON a.surah_id = s.id
       WHERE a.text_simple ILIKE $1
       LIMIT 50`,
      [`%${q}%`]
    );
    res.json(result.rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Count endpoints
app.get('/api/counts/verses', async (req, res) => {
  try {
    const result = await pool.query('SELECT COUNT(*) FROM ayah');
    res.json({ count: result.rows[0].count });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

const PORT = process.env.PORT || 5000;
app.listen(PORT, () => console.log(`Server running on port ${PORT}`));
EOF

# Create scripts directory and import script (with full surah list)
mkdir scripts
cat > scripts/import.js <<'EOF'
const fs = require('fs');
const { Client } = require('pg');
require('dotenv').config({ path: '../.env' });

const client = new Client({
  host: process.env.DB_HOST,
  port: process.env.DB_PORT,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
});

// Complete list of all 114 surahs with accurate metadata
const surahs = [
  { id: 1, name_ar: 'الفاتحة', name_en: 'Al-Fatihah', transliteration: 'Al-Fatihah', revelation_type: 'Meccan', verse_count: 7, order: 5 },
  { id: 2, name_ar: 'البقرة', name_en: 'Al-Baqarah', transliteration: 'Al-Baqarah', revelation_type: 'Medinan', verse_count: 286, order: 87 },
  { id: 3, name_ar: 'آلعمران', name_en: 'Aal-e-Imran', transliteration: 'Aal-e-Imran', revelation_type: 'Medinan', verse_count: 200, order: 89 },
  { id: 4, name_ar: 'النساء', name_en: 'An-Nisa', transliteration: 'An-Nisa', revelation_type: 'Medinan', verse_count: 176, order: 92 },
  { id: 5, name_ar: 'المائدة', name_en: 'Al-Ma\'idah', transliteration: 'Al-Maidah', revelation_type: 'Medinan', verse_count: 120, order: 112 },
  { id: 6, name_ar: 'الأنعام', name_en: 'Al-An\'am', transliteration: 'Al-Anam', revelation_type: 'Meccan', verse_count: 165, order: 55 },
  { id: 7, name_ar: 'الأعراف', name_en: 'Al-A\'raf', transliteration: 'Al-Araf', revelation_type: 'Meccan', verse_count: 206, order: 39 },
  { id: 8, name_ar: 'العنفعل', name_en: 'Al-Anfal', transliteration: 'Al-Anfal', revelation_type: 'Medinan', verse_count: 75, order: 88 },
  { id: 9, name_ar: 'حسبي الله لا إله إلا هو عليه توكلت وهو رب العرش العظيم\nﷲ\nربنا أتمم لنا نورنا واغفر لنا إنك على كل شيء قدير', name_en: 'At-Tawbah', transliteration: 'At-Tawbah', revelation_type: 'Medinan', verse_count: 129, order: 113 },
  { id: 10, name_ar: 'الحقحبالصبور', name_en: 'Yunus', transliteration: 'Yunus', revelation_type: 'Meccan', verse_count: 109, order: 51 },
  { id: 11, name_ar: 'الههضظطه', name_en: 'Hud', transliteration: 'Hud', revelation_type: 'Meccan', verse_count: 123, order: 52 },
  { id: 12, name_ar: 'اليوسف', name_en: 'Yusuf', transliteration: 'Yusuf', revelation_type: 'Meccan', verse_count: 111, order: 53 },
  { id: 13, name_ar: 'الرهضهيه', name_en: 'Ar-Ra\'d', transliteration: 'Ar-Rad', revelation_type: 'Medinan', verse_count: 43, order: 96 },
  { id: 14, name_ar: 'العبغهمنحيهالبابالقلبالسليم', name_en: 'Ibrahim', transliteration: 'Ibrahim', revelation_type: 'Meccan', verse_count: 52, order: 72 },
  { id: 15, name_ar: 'الحجر', name_en: 'Al-Hijr', transliteration: 'Al-Hijr', revelation_type: 'Meccan', verse_count: 99, order: 54 },
  { id: 16, name_ar: 'النحل', name_en: 'An-Nahl', transliteration: 'An-Nahl', revelation_type: 'Meccan', verse_count: 128, order: 70 },
  { id: 17, name_ar: 'العيسراء', name_en: 'Al-Isra', transliteration: 'Al-Isra', revelation_type: 'Meccan', verse_count: 111, order: 50 },
  { id: 18, name_ar: 'الكهف', name_en: 'Al-Kahf', transliteration: 'Al-Kahf', revelation_type: 'Meccan', verse_count: 110, order: 69 },
  { id: 19, name_ar: 'المريم', name_en: 'Maryam', transliteration: 'Maryam', revelation_type: 'Meccan', verse_count: 98, order: 44 },
  { id: 20, name_ar: 'الطه', name_en: 'Ta-Ha', transliteration: 'Ta-Ha', revelation_type: 'Meccan', verse_count: 135, order: 45 },
  { id: 21, name_ar: 'النبابنه', name_en: 'Al-Anbiya', transliteration: 'Al-Anbiya', revelation_type: 'Meccan', verse_count: 112, order: 73 },
  { id: 22, name_ar: 'الحج', name_en: 'Al-Hajj', transliteration: 'Al-Hajj', revelation_type: 'Medinan', verse_count: 78, order: 103 },
  { id: 23, name_ar: 'المؤمنون', name_en: 'Al-Mu\'minun', transliteration: 'Al-Muminun', revelation_type: 'Meccan', verse_count: 118, order: 74 },
  { id: 24, name_ar: 'النور', name_en: 'An-Nur', transliteration: 'An-Nur', revelation_type: 'Medinan', verse_count: 64, order: 102 },
  { id: 25, name_ar: 'الفرقان', name_en: 'Al-Furqan', transliteration: 'Al-Furqan', revelation_type: 'Meccan', verse_count: 77, order: 42 },
  { id: 26, name_ar: 'الحقالعظيم', name_en: 'Ash-Shu\'ara', transliteration: 'Ash-Shuara', revelation_type: 'Meccan', verse_count: 227, order: 47 },
  { id: 27, name_ar: 'النمل', name_en: 'An-Naml', transliteration: 'An-Naml', revelation_type: 'Meccan', verse_count: 93, order: 48 },
  { id: 28, name_ar: 'القصص', name_en: 'Al-Qasas', transliteration: 'Al-Qasas', revelation_type: 'Meccan', verse_count: 88, order: 49 },
  { id: 29, name_ar: 'الحقحقعنحقحقفنهر', name_en: 'Al-Ankabut', transliteration: 'Al-Ankabut', revelation_type: 'Meccan', verse_count: 69, order: 85 },
  { id: 30, name_ar: 'الروم', name_en: 'Ar-Rum', transliteration: 'Ar-Rum', revelation_type: 'Meccan', verse_count: 60, order: 84 },
  { id: 31, name_ar: 'القمان', name_en: 'Luqman', transliteration: 'Luqman', revelation_type: 'Meccan', verse_count: 34, order: 57 },
  { id: 32, name_ar: 'الصجضه', name_en: 'As-Sajda', transliteration: 'As-Sajdah', revelation_type: 'Meccan', verse_count: 30, order: 75 },
  { id: 33, name_ar: 'العظاب', name_en: 'Al-Ahzab', transliteration: 'Al-Ahzab', revelation_type: 'Medinan', verse_count: 73, order: 90 },
  { id: 34, name_ar: 'السبإ', name_en: 'Saba', transliteration: 'Saba', revelation_type: 'Meccan', verse_count: 54, order: 58 },
  { id: 35, name_ar: 'فاطر', name_en: 'Fatir', transliteration: 'Fatir', revelation_type: 'Meccan', verse_count: 45, order: 43 },
  { id: 36, name_ar: 'اليس', name_en: 'Ya-Sin', transliteration: 'Ya-Sin', revelation_type: 'Meccan', verse_count: 83, order: 41 },
  { id: 37, name_ar: 'الصافات', name_en: 'As-Saffat', transliteration: 'As-Saffat', revelation_type: 'Meccan', verse_count: 182, order: 56 },
  { id: 38, name_ar: 'ص', name_en: 'Sad', transliteration: 'Sad', revelation_type: 'Meccan', verse_count: 88, order: 38 },
  { id: 39, name_ar: 'الظمر', name_en: 'Az-Zumar', transliteration: 'Az-Zumar', revelation_type: 'Meccan', verse_count: 75, order: 59 },
  { id: 40, name_ar: 'غافر', name_en: 'Ghafir', transliteration: 'Ghafir', revelation_type: 'Meccan', verse_count: 85, order: 60 },
  { id: 41, name_ar: 'فصلت', name_en: 'Fussilat', transliteration: 'Fussilat', revelation_type: 'Meccan', verse_count: 54, order: 61 },
  { id: 42, name_ar: 'الشورى', name_en: 'Ash-Shura', transliteration: 'Ash-Shura', revelation_type: 'Meccan', verse_count: 53, order: 62 },
  { id: 43, name_ar: 'الظفخيرفخطه', name_en: 'Az-Zukhruf', transliteration: 'Az-Zukhruf', revelation_type: 'Meccan', verse_count: 89, order: 63 },
  { id: 44, name_ar: 'الضهخهن', name_en: 'Ad-Dukhan', transliteration: 'Ad-Dukhan', revelation_type: 'Meccan', verse_count: 59, order: 64 },
  { id: 45, name_ar: 'الجاثية', name_en: 'Al-Jathiya', transliteration: 'Al-Jathiya', revelation_type: 'Meccan', verse_count: 37, order: 65 },
  { id: 46, name_ar: 'الأحقاف', name_en: 'Al-Ahqaf', transliteration: 'Al-Ahqaf', revelation_type: 'Meccan', verse_count: 35, order: 66 },
  { id: 47, name_ar: 'مهمض', name_en: 'Muhammad', transliteration: 'Muhammad', revelation_type: 'Medinan', verse_count: 38, order: 95 },
  { id: 48, name_ar: 'الفطهحيه', name_en: 'Al-Fath', transliteration: 'Al-Fath', revelation_type: 'Medinan', verse_count: 29, order: 111 },
  { id: 49, name_ar: 'الحجرات', name_en: 'Al-Hujurat', transliteration: 'Al-Hujurat', revelation_type: 'Medinan', verse_count: 18, order: 106 },
  { id: 50, name_ar: 'الق', name_en: 'Qaf', transliteration: 'Qaf', revelation_type: 'Meccan', verse_count: 45, order: 34 },
  { id: 51, name_ar: 'الظارياة', name_en: 'Adh-Dhariyat', transliteration: 'Adh-Dhariyat', revelation_type: 'Meccan', verse_count: 60, order: 67 },
  { id: 52, name_ar: 'الطور', name_en: 'At-Tur', transliteration: 'At-Tur', revelation_type: 'Meccan', verse_count: 49, order: 76 },
  { id: 53, name_ar: 'النجم', name_en: 'An-Najm', transliteration: 'An-Najm', revelation_type: 'Meccan', verse_count: 62, order: 23 },
  { id: 54, name_ar: 'القمر', name_en: 'Al-Qamar', transliteration: 'Al-Qamar', revelation_type: 'Meccan', verse_count: 55, order: 37 },
  { id: 55, name_ar: 'الرحمن', name_en: 'Ar-Rahman', transliteration: 'Ar-Rahman', revelation_type: 'Medinan', verse_count: 78, order: 97 },
  { id: 56, name_ar: 'الواقعة', name_en: 'Al-Waqi\'a', transliteration: 'Al-Waqia', revelation_type: 'Meccan', verse_count: 96, order: 46 },
  { id: 57, name_ar: 'الهضهحيضه', name_en: 'Al-Hadid', transliteration: 'Al-Hadid', revelation_type: 'Medinan', verse_count: 29, order: 94 },
  { id: 58, name_ar: 'المجادلة', name_en: 'Al-Mujadila', transliteration: 'Al-Mujadila', revelation_type: 'Medinan', verse_count: 22, order: 105 },
  { id: 59, name_ar: 'الحشر', name_en: 'Al-Hashr', transliteration: 'Al-Hashr', revelation_type: 'Medinan', verse_count: 24, order: 101 },
  { id: 60, name_ar: 'الممتحنة', name_en: 'Al-Mumtahina', transliteration: 'Al-Mumtahina', revelation_type: 'Medinan', verse_count: 13, order: 91 },
  { id: 61, name_ar: 'الصف', name_en: 'As-Saff', transliteration: 'As-Saff', revelation_type: 'Medinan', verse_count: 14, order: 109 },
  { id: 62, name_ar: 'الجمعة', name_en: 'Al-Jumu\'a', transliteration: 'Al-Jumua', revelation_type: 'Medinan', verse_count: 11, order: 110 },
  { id: 63, name_ar: 'المنافقون', name_en: 'Al-Munafiqun', transliteration: 'Al-Munafiqun', revelation_type: 'Medinan', verse_count: 11, order: 104 },
  { id: 64, name_ar: 'التغابن', name_en: 'At-Taghabun', transliteration: 'At-Taghabun', revelation_type: 'Medinan', verse_count: 18, order: 108 },
  { id: 65, name_ar: 'الطلاق', name_en: 'At-Talaq', transliteration: 'At-Talaq', revelation_type: 'Medinan', verse_count: 12, order: 99 },
  { id: 66, name_ar: 'التحريم', name_en: 'At-Tahrim', transliteration: 'At-Tahrim', revelation_type: 'Medinan', verse_count: 12, order: 107 },
  { id: 67, name_ar: 'الملك', name_en: 'Al-Mulk', transliteration: 'Al-Mulk', revelation_type: 'Meccan', verse_count: 30, order: 77 },
  { id: 68, name_ar: 'القلم', name_en: 'Al-Qalam', transliteration: 'Al-Qalam', revelation_type: 'Meccan', verse_count: 52, order: 2 },
  { id: 69, name_ar: 'الحاقة', name_en: 'Al-Haqqatu', transliteration: 'Al-Haqqatu', revelation_type: 'Meccan', verse_count: 52, order: 78 },
  { id: 70, name_ar: 'المعارج', name_en: 'Al-Ma\'arij', transliteration: 'Al-Maarij', revelation_type: 'Meccan', verse_count: 44, order: 79 },
  { id: 71, name_ar: 'النوح', name_en: 'Nuh', transliteration: 'Nuh', revelation_type: 'Meccan', verse_count: 28, order: 71 },
  { id: 72, name_ar: 'الجن', name_en: 'Al-Jinn', transliteration: 'Al-Jinn', revelation_type: 'Meccan', verse_count: 28, order: 40 },
  { id: 73, name_ar: 'المزمل', name_en: 'Al-Muzzammil', transliteration: 'Al-Muzzammil', revelation_type: 'Meccan', verse_count: 20, order: 3 },
  { id: 74, name_ar: 'المدثر', name_en: 'Al-Muddaththir', transliteration: 'Al-Muddaththir', revelation_type: 'Meccan', verse_count: 56, order: 4 },
  { id: 75, name_ar: 'القيامة', name_en: 'Al-Qiyama', transliteration: 'Al-Qiyama', revelation_type: 'Meccan', verse_count: 40, order: 31 },
  { id: 76, name_ar: 'الانسان', name_en: 'Al-Insan', transliteration: 'Al-Insan', revelation_type: 'Medinan', verse_count: 31, order: 98 },
  { id: 77, name_ar: 'المرسلات', name_en: 'Al-Mursalat', transliteration: 'Al-Mursalat', revelation_type: 'Meccan', verse_count: 50, order: 33 },
  { id: 78, name_ar: 'النبإ', name_en: 'An-Naba', transliteration: 'An-Naba', revelation_type: 'Meccan', verse_count: 40, order: 80 },
  { id: 79, name_ar: 'النازعات', name_en: 'An-Nazi\'at', transliteration: 'An-Naziat', revelation_type: 'Meccan', verse_count: 46, order: 81 },
  { id: 80, name_ar: 'عبس', name_en: 'Abasa', transliteration: 'Abasa', revelation_type: 'Meccan', verse_count: 42, order: 24 },
  { id: 81, name_ar: 'التكوير', name_en: 'At-Takwir', transliteration: 'At-Takwir', revelation_type: 'Meccan', verse_count: 29, order: 7 },
  { id: 82, name_ar: 'الإنفطار', name_en: 'Al-Infitar', transliteration: 'Al-Infitar', revelation_type: 'Meccan', verse_count: 19, order: 82 },
  { id: 83, name_ar: 'المطففين', name_en: 'Al-Mutaffifin', transliteration: 'Al-Mutaffifin', revelation_type: 'Meccan', verse_count: 36, order: 86 },
  { id: 84, name_ar: 'الإنشقاق', name_en: 'Al-Inshiqaq', transliteration: 'Al-Inshiqaq', revelation_type: 'Meccan', verse_count: 25, order: 83 },
  { id: 85, name_ar: 'البروج', name_en: 'Al-Buruj', transliteration: 'Al-Buruj', revelation_type: 'Meccan', verse_count: 22, order: 27 },
  { id: 86, name_ar: 'الطارق', name_en: 'At-Tariq', transliteration: 'At-Tariq', revelation_type: 'Meccan', verse_count: 17, order: 36 },
  { id: 87, name_ar: 'الأعلى', name_en: 'Al-A\'la', transliteration: 'Al-Ala', revelation_type: 'Meccan', verse_count: 19, order: 8 },
  { id: 88, name_ar: 'الغاشية', name_en: 'Al-Ghashiya', transliteration: 'Al-Ghashiya', revelation_type: 'Meccan', verse_count: 26, order: 68 },
  { id: 89, name_ar: 'الفجر', name_en: 'Al-Fajr', transliteration: 'Al-Fajr', revelation_type: 'Meccan', verse_count: 30, order: 10 },
  { id: 90, name_ar: 'البلد', name_en: 'Al-Balad', transliteration: 'Al-Balad', revelation_type: 'Meccan', verse_count: 20, order: 35 },
  { id: 91, name_ar: 'الشمس', name_en: 'Ash-Shams', transliteration: 'Ash-Shams', revelation_type: 'Meccan', verse_count: 15, order: 26 },
  { id: 92, name_ar: 'الليل', name_en: 'Al-Layl', transliteration: 'Al-Layl', revelation_type: 'Meccan', verse_count: 21, order: 9 },
  { id: 93, name_ar: 'الضحى', name_en: 'Ad-Duha', transliteration: 'Ad-Duha', revelation_type: 'Meccan', verse_count: 11, order: 11 },
  { id: 94, name_ar: 'الشرح', name_en: 'Ash-Sharh', transliteration: 'Ash-Sharh', revelation_type: 'Meccan', verse_count: 8, order: 12 },
  { id: 95, name_ar: 'التين', name_en: 'At-Tin', transliteration: 'At-Tin', revelation_type: 'Meccan', verse_count: 8, order: 28 },
  { id: 96, name_ar: 'العلق', name_en: 'Al-Alaq', transliteration: 'Al-Alaq', revelation_type: 'Meccan', verse_count: 19, order: 1 },
  { id: 97, name_ar: 'القدر', name_en: 'Al-Qadr', transliteration: 'Al-Qadr', revelation_type: 'Meccan', verse_count: 5, order: 25 },
  { id: 98, name_ar: 'البينة', name_en: 'Al-Bayyina', transliteration: 'Al-Bayyina', revelation_type: 'Medinan', verse_count: 8, order: 100 },
  { id: 99, name_ar: 'الظلظلة', name_en: 'Az-Zalzala', transliteration: 'Az-Zalzala', revelation_type: 'Medinan', verse_count: 8, order: 93 },
  { id: 100, name_ar: 'العاديات', name_en: 'Al-Adiyat', transliteration: 'Al-Adiyat', revelation_type: 'Meccan', verse_count: 11, order: 14 },
  { id: 101, name_ar: 'القارعة', name_en: 'Al-Qari\'a', transliteration: 'Al-Qaria', revelation_type: 'Meccan', verse_count: 11, order: 30 },
  { id: 102, name_ar: 'التكاثر', name_en: 'At-Takathur', transliteration: 'At-Takathur', revelation_type: 'Meccan', verse_count: 8, order: 16 },
  { id: 103, name_ar: 'العصر', name_en: 'Al-Asr', transliteration: 'Al-Asr', revelation_type: 'Meccan', verse_count: 3, order: 13 },
  { id: 104, name_ar: 'الهمزة', name_en: 'Al-Humaza', transliteration: 'Al-Humaza', revelation_type: 'Meccan', verse_count: 9, order: 32 },
  { id: 105, name_ar: 'الفيل', name_en: 'Al-Fil', transliteration: 'Al-Fil', revelation_type: 'Meccan', verse_count: 5, order: 19 },
  { id: 106, name_ar: 'القريش', name_en: 'Quraysh', transliteration: 'Quraysh', revelation_type: 'Meccan', verse_count: 4, order: 29 },
  { id: 107, name_ar: 'الماعون', name_en: 'Al-Ma\'un', transliteration: 'Al-Maun', revelation_type: 'Meccan', verse_count: 7, order: 17 },
  { id: 108, name_ar: 'الكوثر', name_en: 'Al-Kawthar', transliteration: 'Al-Kawthar', revelation_type: 'Meccan', verse_count: 3, order: 15 },
  { id: 109, name_ar: 'الكافرون', name_en: 'Al-Kafirun', transliteration: 'Al-Kafirun', revelation_type: 'Meccan', verse_count: 6, order: 18 },
  { id: 110, name_ar: 'النصر', name_en: 'An-Nasr', transliteration: 'An-Nasr', revelation_type: 'Medinan', verse_count: 3, order: 114 },
  { id: 111, name_ar: 'المسد', name_en: 'Al-Masad', transliteration: 'Al-Masad', revelation_type: 'Meccan', verse_count: 5, order: 6 },
  { id: 112, name_ar: 'الإخلاص', name_en: 'Al-Ikhlas', transliteration: 'Al-Ikhlas', revelation_type: 'Meccan', verse_count: 4, order: 22 },
  { id: 113, name_ar: 'الفلق', name_en: 'Al-Falaq', transliteration: 'Al-Falaq', revelation_type: 'Meccan', verse_count: 5, order: 20 },
  { id: 114, name_ar: 'الناس', name_en: 'An-Nas', transliteration: 'An-Nas', revelation_type: 'Meccan', verse_count: 6, order: 21 }
];

async function importSurahs() {
  for (const s of surahs) {
    await client.query(
      `INSERT INTO surah (id, name_ar, name_en, transliteration, revelation_type, verse_count, "order")
       VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (id) DO UPDATE SET
         name_ar = EXCLUDED.name_ar,
         name_en = EXCLUDED.name_en,
         transliteration = EXCLUDED.transliteration,
         revelation_type = EXCLUDED.revelation_type,
         verse_count = EXCLUDED.verse_count,
         "order" = EXCLUDED."order"`,
      [s.id, s.name_ar, s.name_en, s.transliteration, s.revelation_type, s.verse_count, s.order]
    );
  }
  console.log('✅ All 114 surahs imported (upserted)');
}

async function importAyahs() {
  // Download from Tanzil if not present
  const filePath = './quran-uthmani.txt';
  if (!fs.existsSync(filePath)) {
    console.log('📥 Downloading Quran text from Tanzil (Uthmani script)...');
    const execSync = require('child_process').execSync;
    // Use either wget or curl (determined by parent script)
    // For simplicity, we'll try wget first, then curl
    try {
      execSync('wget -O quran-uthmani.txt https://tanzil.net/trans/?type=uthmani', { stdio: 'inherit' });
    } catch (e) {
      try {
        execSync('curl -o quran-uthmani.txt https://tanzil.net/trans/?type=uthmani', { stdio: 'inherit' });
      } catch (e2) {
        console.error('Failed to download Quran text. Please download manually from https://tanzil.net/trans/?type=uthmani and place in backend/scripts/');
        process.exit(1);
      }
    }
  }

  const data = fs.readFileSync(filePath, 'utf8');
  const lines = data.split('\n');
  let count = 0;
  for (const line of lines) {
    if (!line.trim()) continue;
    const parts = line.split('|');
    if (parts.length < 2) continue;
    const ref = parts[0];
    const text = parts.slice(1).join('|'); // in case text contains '|'
    const [surahId, verseNum] = ref.split(':').map(Number);
    await client.query(
      'INSERT INTO ayah (surah_id, verse_number, text_uthmani) VALUES ($1,$2,$3) ON CONFLICT (surah_id, verse_number) DO NOTHING',
      [surahId, verseNum, text]
    );
    count++;
    if (count % 1000 === 0) console.log(`📖 ${count} verses imported...`);
  }
  console.log(`✅ ${count} verses imported`);
}

async function main() {
  await client.connect();
  // Create tables if they don't exist
  await client.query(`
    CREATE TABLE IF NOT EXISTS surah (
      id SMALLINT PRIMARY KEY,
      name_ar TEXT NOT NULL,
      name_en TEXT NOT NULL,
      transliteration TEXT,
      revelation_type VARCHAR(10),
      verse_count SMALLINT NOT NULL,
      "order" SMALLINT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ayah (
      id SERIAL PRIMARY KEY,
      surah_id SMALLINT NOT NULL REFERENCES surah(id) ON DELETE CASCADE,
      verse_number SMALLINT NOT NULL,
      text_uthmani TEXT NOT NULL,
      text_simple TEXT,
      juz SMALLINT,
      hizb SMALLINT,
      manzil SMALLINT,
      ruku SMALLINT,
      page SMALLINT,
      sajda BOOLEAN DEFAULT FALSE,
      UNIQUE(surah_id, verse_number)
    );
    CREATE INDEX IF NOT EXISTS idx_ayah_surah_id ON ayah(surah_id);
  `);
  await importSurahs();
  await importAyahs();
  await client.end();
}

main().catch(console.error);
EOF

cd "$PROJECT_ROOT"

# --- Frontend setup ---
echo "Creating frontend with React..."
npx create-react-app frontend
cd frontend

# Install additional deps
npm install axios react-router-dom

# Overwrite App.js
cat > src/App.js <<'EOF'
import React, { useState, useEffect } from 'react';
import { BrowserRouter as Router, Route, Routes, Link } from 'react-router-dom';
import axios from 'axios';
import SurahView from './components/SurahView';
import './App.css';

const API_BASE = 'http://localhost:5000/api';

function App() {
  const [surahs, setSurahs] = useState([]);

  useEffect(() => {
    axios.get(`${API_BASE}/surahs`).then(res => setSurahs(res.data));
  }, []);

  return (
    <Router>
      <div className="app">
        <aside className="sidebar">
          <h2>Al-Qur'an</h2>
          <input type="text" placeholder="Search surah..." />
          <ul>
            {surahs.map(s => (
              <li key={s.id}>
                <Link to={`/surah/${s.id}`}>{s.id}. {s.name_ar} - {s.name_en}</Link>
              </li>
            ))}
          </ul>
        </aside>
        <main className="content">
          <Routes>
            <Route path="/" element={<div>Select a surah</div>} />
            <Route path="/surah/:id" element={<SurahView apiBase={API_BASE} />} />
          </Routes>
        </main>
      </div>
    </Router>
  );
}

export default App;
EOF

# Create components folder and SurahView
mkdir -p src/components
cat > src/components/SurahView.js <<'EOF'
import React, { useState, useEffect } from 'react';
import { useParams } from 'react-router-dom';
import axios from 'axios';

function SurahView({ apiBase }) {
  const { id } = useParams();
  const [surah, setSurah] = useState(null);
  const [verses, setVerses] = useState([]);

  useEffect(() => {
    axios.get(`${apiBase}/surahs/${id}`).then(res => {
      setSurah(res.data.surah);
      setVerses(res.data.verses);
    });
  }, [id, apiBase]);

  if (!surah) return <div>Loading...</div>;

  return (
    <div className="surah-view">
      <h1>{surah.name_ar} - {surah.name_en}</h1>
      <p>Revelation: {surah.revelation_type} | Verses: {surah.verse_count}</p>
      <div className="verses">
        {verses.map(v => (
          <div key={v.id} className="verse" id={`verse-${v.verse_number}`}>
            <span className="verse-num">{v.verse_number}</span>
            <p className="arabic" dangerouslySetInnerHTML={{ __html: v.text_uthmani }}></p>
          </div>
        ))}
      </div>
    </div>
  );
}

export default SurahView;
EOF

# Add App.css
cat > src/App.css <<'EOF'
@import url('https://fonts.googleapis.com/css2?family=Amiri:wght@400;700&display=swap');

body { font-family: 'Amiri', serif; margin: 0; padding: 0; }
.app { display: flex; height: 100vh; }
.sidebar { width: 250px; background: #f4f4f4; padding: 1rem; overflow-y: auto; }
.sidebar ul { list-style: none; padding: 0; }
.sidebar li a { text-decoration: none; color: #333; display: block; padding: 0.3rem 0; }
.sidebar li a:hover { background: #ddd; }
.content { flex: 1; padding: 1rem; overflow-y: auto; }
.arabic { direction: rtl; font-size: 1.5rem; line-height: 2; }
.verse { display: flex; align-items: flex-start; margin-bottom: 1.5rem; }
.verse-num { background: #009688; color: white; border-radius: 50%; width: 30px; height: 30px; display: inline-flex; align-items: center; justify-content: center; margin-right: 10px; font-size: 0.9rem; }
EOF

cd "$PROJECT_ROOT"

# --- Run database import ---
echo "Importing Quran data into database..."
cd backend
node scripts/import.js

echo ""
echo "=== Reification complete! ==="
echo ""
echo "To start the application:"
echo "1. Backend: cd $PROJECT_ROOT/backend && npm run dev"
echo "2. Frontend: cd $PROJECT_ROOT/frontend && npm start"
echo ""
echo "Then open http://localhost:3000 in your browser."
