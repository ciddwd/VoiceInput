// Package snippets owns the user-curated quick-text library: categories
// (programming / video / prompt …) plus the entries inside each, persisted
// to a small SQLite file in the user's config directory.
package snippets

import "time"

// Category groups snippets and can attach automatic prefix/suffix to anything
// sent while it's the active category — useful for "all prompts get framed
// with 【Prompt】 / 。" or "tab-out after every commit message".
type Category struct {
	ID                int64     `json:"id"`
	Name              string    `json:"name"`
	Prefix            string    `json:"prefix"`
	Suffix            string    `json:"suffix"`
	DefaultSendSuffix string    `json:"defaultSendSuffix"` // enter / tab / space / ctrl+enter / …
	MatchAppRegex     string    `json:"matchAppRegex"`     // regex against host process name; auto-select
	Sort              int       `json:"sort"`
	UpdatedAt         time.Time `json:"updatedAt"`
}

// Snippet is one quick-insert text under a category. Hotkey is reserved for a
// later phase (numeric/letter shortcut when the chip row has keyboard focus).
type Snippet struct {
	ID         int64     `json:"id"`
	CategoryID int64     `json:"categoryId"`
	Label      string    `json:"label"`
	Content    string    `json:"content"`
	Hotkey     string    `json:"hotkey,omitempty"`
	Sort       int       `json:"sort"`
	UpdatedAt  time.Time `json:"updatedAt"`
}

// DictionaryEntry is a single user-curated term (proper noun, domain word,
// project codename, brand) that the ASR engine should preserve and that the
// polish prompt instructs the LLM not to "correct" away.
type DictionaryEntry struct {
	ID        int64     `json:"id"`
	Term      string    `json:"term"`
	Sort      int       `json:"sort"`
	UpdatedAt time.Time `json:"updatedAt"`
}

// Snapshot is the full library state — what the desktop pushes to a freshly
// connected mobile, and what the Snippets management UI binds to.
type Snapshot struct {
	Categories []Category        `json:"categories"`
	Snippets   []Snippet         `json:"snippets"`
	Dictionary []DictionaryEntry `json:"dictionary"`
	Revision   int64             `json:"revision"`
}
