package snippets

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// Store wraps the SQLite database for the snippet library. Methods are
// goroutine-safe; the underlying sql.DB handles concurrency for us, with a
// thin Go-side mutex around revision bumping.
type Store struct {
	db  *sql.DB
	mu  sync.Mutex
	rev int64
}

// Open initialises the database file (creating parent dirs as needed) and
// applies the schema. Safe to call on first run.
func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("mkdir: %w", err)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1) // SQLite single-writer; cheaper than wrestling with WAL contention
	if _, err := db.Exec(`PRAGMA journal_mode = WAL;`); err != nil {
		return nil, fmt.Errorf("set wal: %w", err)
	}
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		return nil, err
	}
	if err := s.seedIfEmpty(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS categories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  prefix TEXT NOT NULL DEFAULT '',
  suffix TEXT NOT NULL DEFAULT '',
  default_send_suffix TEXT NOT NULL DEFAULT '',
  match_app_regex TEXT NOT NULL DEFAULT '',
  sort INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS snippets (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  content TEXT NOT NULL,
  hotkey TEXT NOT NULL DEFAULT '',
  sort INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_snippets_category ON snippets(category_id);
CREATE TABLE IF NOT EXISTS dictionary (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  term TEXT NOT NULL UNIQUE,
  sort INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);
`)
	return err
}

func (s *Store) seedIfEmpty() error {
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM categories`).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	now := time.Now().Unix()
	seed := []struct {
		Name, Prefix, Suffix, SendSuffix, AppRegex string
		Items                                      []struct{ Label, Content string }
	}{
		{
			Name: "编程类", SendSuffix: "ctrl+enter",
			AppRegex: `(?i)(code|cursor|webstorm|goland|idea|pycharm|sublime|terminal)`,
			Items: []struct{ Label, Content string }{
				{"重构这段", "请重构以下代码，目标是更清晰、更可维护，但行为不变："},
				{"解释一下", "请解释下面这段代码的工作原理、关键流程和潜在边界条件："},
				{"补测试", "请为以下代码补充单元测试，覆盖正常路径和典型边界："},
				{"修这个 bug", "下面这段代码有 bug，请定位原因并提交修复："},
			},
		},
		{
			Name: "视频类", SendSuffix: "enter",
			AppRegex: `(?i)(premiere|davinci|finalcut|capcut|edius|vegas)`,
			Items: []struct{ Label, Content string }{
				{"加字幕", "请为此片段生成时间码对齐的中文字幕。"},
				{"分镜建议", "请给出这段视频的分镜建议，包括镜头时长、景别、运镜。"},
			},
		},
		{
			Name: "Prompt 类", Prefix: "【Prompt】", Suffix: "", SendSuffix: "enter",
			Items: []struct{ Label, Content string }{
				{"扮演专家", "你是该领域的资深专家。请基于以下问题给出专业、谨慎、可执行的回答。"},
				{"分步骤", "请将上述问题分解为清晰的步骤，每一步给出可立即执行的操作。"},
				{"挑反例", "请给出至少三个可能让上述结论失效的反例或边界情况。"},
			},
		},
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	for i, c := range seed {
		res, err := tx.Exec(
			`INSERT INTO categories(name, prefix, suffix, default_send_suffix, match_app_regex, sort, updated_at)
             VALUES(?, ?, ?, ?, ?, ?, ?)`,
			c.Name, c.Prefix, c.Suffix, c.SendSuffix, c.AppRegex, i, now,
		)
		if err != nil {
			_ = tx.Rollback()
			return err
		}
		catID, _ := res.LastInsertId()
		for j, it := range c.Items {
			if _, err := tx.Exec(
				`INSERT INTO snippets(category_id, label, content, sort, updated_at) VALUES(?, ?, ?, ?, ?)`,
				catID, it.Label, it.Content, j, now,
			); err != nil {
				_ = tx.Rollback()
				return err
			}
		}
	}
	return tx.Commit()
}

// Snapshot returns the entire library plus an opaque revision number that
// monotonically increases with every mutation. Callers compare revisions to
// detect "did anything change" without doing a deep diff.
func (s *Store) Snapshot() (Snapshot, error) {
	s.mu.Lock()
	rev := s.rev
	s.mu.Unlock()

	out := Snapshot{Revision: rev}
	rows, err := s.db.Query(`SELECT id,name,prefix,suffix,default_send_suffix,match_app_regex,sort,updated_at FROM categories ORDER BY sort, id`)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var c Category
		var ts int64
		if err := rows.Scan(&c.ID, &c.Name, &c.Prefix, &c.Suffix, &c.DefaultSendSuffix, &c.MatchAppRegex, &c.Sort, &ts); err != nil {
			rows.Close()
			return out, err
		}
		c.UpdatedAt = time.Unix(ts, 0)
		out.Categories = append(out.Categories, c)
	}
	rows.Close()

	rows, err = s.db.Query(`SELECT id,category_id,label,content,hotkey,sort,updated_at FROM snippets ORDER BY category_id, sort, id`)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var n Snippet
		var ts int64
		if err := rows.Scan(&n.ID, &n.CategoryID, &n.Label, &n.Content, &n.Hotkey, &n.Sort, &ts); err != nil {
			rows.Close()
			return out, err
		}
		n.UpdatedAt = time.Unix(ts, 0)
		out.Snippets = append(out.Snippets, n)
	}
	rows.Close()

	rows, err = s.db.Query(`SELECT id,term,sort,updated_at FROM dictionary ORDER BY sort, id`)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var d DictionaryEntry
		var ts int64
		if err := rows.Scan(&d.ID, &d.Term, &d.Sort, &ts); err != nil {
			rows.Close()
			return out, err
		}
		d.UpdatedAt = time.Unix(ts, 0)
		out.Dictionary = append(out.Dictionary, d)
	}
	rows.Close()
	return out, nil
}

// CreateDictionaryEntry inserts a term, ignoring duplicates (UNIQUE on term).
func (s *Store) CreateDictionaryEntry(term string, sort int) (int64, error) {
	now := time.Now().Unix()
	res, err := s.db.Exec(
		`INSERT OR IGNORE INTO dictionary(term, sort, updated_at) VALUES(?, ?, ?)`,
		term, sort, now,
	)
	if err != nil {
		return 0, err
	}
	id, _ := res.LastInsertId()
	if id > 0 {
		s.bumpRev()
	}
	return id, nil
}

func (s *Store) UpdateDictionaryEntry(d DictionaryEntry) error {
	if d.ID == 0 {
		return errors.New("dictionary id required")
	}
	_, err := s.db.Exec(
		`UPDATE dictionary SET term=?, sort=?, updated_at=? WHERE id=?`,
		d.Term, d.Sort, time.Now().Unix(), d.ID,
	)
	if err == nil {
		s.bumpRev()
	}
	return err
}

func (s *Store) DeleteDictionaryEntry(id int64) error {
	_, err := s.db.Exec(`DELETE FROM dictionary WHERE id=?`, id)
	if err == nil {
		s.bumpRev()
	}
	return err
}

// ReplaceDictionary swaps the whole dictionary atomically — handy when the UI
// edits a chip cloud with arbitrary insertions/deletions and just sends the
// final list.
func (s *Store) ReplaceDictionary(terms []string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM dictionary`); err != nil {
		_ = tx.Rollback()
		return err
	}
	now := time.Now().Unix()
	for i, t := range terms {
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		if _, err := tx.Exec(
			`INSERT OR IGNORE INTO dictionary(term, sort, updated_at) VALUES(?, ?, ?)`,
			t, i, now,
		); err != nil {
			_ = tx.Rollback()
			return err
		}
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	s.bumpRev()
	return nil
}

func (s *Store) CreateCategory(c Category) (int64, error) {
	now := time.Now().Unix()
	res, err := s.db.Exec(
		`INSERT INTO categories(name,prefix,suffix,default_send_suffix,match_app_regex,sort,updated_at) VALUES(?,?,?,?,?,?,?)`,
		c.Name, c.Prefix, c.Suffix, c.DefaultSendSuffix, c.MatchAppRegex, c.Sort, now,
	)
	if err != nil {
		return 0, err
	}
	s.bumpRev()
	return res.LastInsertId()
}

func (s *Store) UpdateCategory(c Category) error {
	if c.ID == 0 {
		return errors.New("category id required")
	}
	_, err := s.db.Exec(
		`UPDATE categories SET name=?, prefix=?, suffix=?, default_send_suffix=?, match_app_regex=?, sort=?, updated_at=? WHERE id=?`,
		c.Name, c.Prefix, c.Suffix, c.DefaultSendSuffix, c.MatchAppRegex, c.Sort, time.Now().Unix(), c.ID,
	)
	if err == nil {
		s.bumpRev()
	}
	return err
}

func (s *Store) DeleteCategory(id int64) error {
	_, err := s.db.Exec(`DELETE FROM categories WHERE id=?`, id)
	if err == nil {
		s.bumpRev()
	}
	return err
}

func (s *Store) CreateSnippet(n Snippet) (int64, error) {
	now := time.Now().Unix()
	res, err := s.db.Exec(
		`INSERT INTO snippets(category_id,label,content,hotkey,sort,updated_at) VALUES(?,?,?,?,?,?)`,
		n.CategoryID, n.Label, n.Content, n.Hotkey, n.Sort, now,
	)
	if err != nil {
		return 0, err
	}
	s.bumpRev()
	return res.LastInsertId()
}

func (s *Store) UpdateSnippet(n Snippet) error {
	if n.ID == 0 {
		return errors.New("snippet id required")
	}
	_, err := s.db.Exec(
		`UPDATE snippets SET category_id=?, label=?, content=?, hotkey=?, sort=?, updated_at=? WHERE id=?`,
		n.CategoryID, n.Label, n.Content, n.Hotkey, n.Sort, time.Now().Unix(), n.ID,
	)
	if err == nil {
		s.bumpRev()
	}
	return err
}

func (s *Store) DeleteSnippet(id int64) error {
	_, err := s.db.Exec(`DELETE FROM snippets WHERE id=?`, id)
	if err == nil {
		s.bumpRev()
	}
	return err
}

func (s *Store) bumpRev() {
	s.mu.Lock()
	s.rev++
	s.mu.Unlock()
}

// Revision returns the current revision number — useful for the server to
// decide whether to broadcast a new snapshot.
func (s *Store) Revision() int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.rev
}
