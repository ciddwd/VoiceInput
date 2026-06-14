import {useEffect, useMemo, useState} from 'react';
import {t, useLocale} from '../i18n';
import {
    DeleteCategory,
    DeleteSnippet,
    GetSnippets,
    SaveCategory,
    SaveSnippet,
} from '../../wailsjs/go/main/App';
import {EventsOn} from '../../wailsjs/runtime/runtime';

type Category = {
    id: number;
    name: string;
    prefix: string;
    suffix: string;
    defaultSendSuffix: string;
    matchAppRegex: string;
    sort: number;
};

type Snippet = {
    id: number;
    categoryId: number;
    label: string;
    content: string;
    hotkey?: string;
    sort: number;
};

type Snapshot = { categories: Category[]; snippets: Snippet[]; revision: number };

const emptyCategory: Category = {
    id: 0, name: '', prefix: '', suffix: '',
    defaultSendSuffix: '', matchAppRegex: '', sort: 0,
};

export function SnippetsPage() {
    useLocale();
    const [snap, setSnap] = useState<Snapshot>({categories: [], snippets: [], revision: 0});
    const [selectedCatId, setSelectedCatId] = useState<number | null>(null);
    const [editingCategory, setEditingCategory] = useState<Category | null>(null);
    const [editingSnippet, setEditingSnippet] = useState<Snippet | null>(null);

    useEffect(() => {
        GetSnippets().then((s: any) => {
            setSnap(s as Snapshot);
            if (s && s.categories && s.categories.length && selectedCatId == null) {
                setSelectedCatId(s.categories[0].id);
            }
        });
        const off = EventsOn('snippets:changed', (s: Snapshot) => setSnap(s));
        return () => off();
    }, []);

    const categories = snap.categories;
    const currentSnippets = useMemo(
        () => snap.snippets.filter((n) => n.categoryId === selectedCatId),
        [snap.snippets, selectedCatId],
    );
    const currentCategory = categories.find((c) => c.id === selectedCatId) ?? null;

    const startNewCategory = () => setEditingCategory({...emptyCategory});
    const startEditCategory = (c: Category) => setEditingCategory({...c});

    const saveCategory = async (c: Category) => {
        const id = await SaveCategory(c as any);
        setEditingCategory(null);
        if (c.id === 0) setSelectedCatId(id as number);
    };
    const removeCategory = async (id: number) => {
        if (!confirm(t('snip.confirmDelCat'))) return;
        await DeleteCategory(id);
        if (selectedCatId === id) setSelectedCatId(null);
    };

    const startNewSnippet = () => {
        if (selectedCatId == null) return;
        setEditingSnippet({id: 0, categoryId: selectedCatId, label: '', content: '', sort: currentSnippets.length});
    };
    const startEditSnippet = (n: Snippet) => setEditingSnippet({...n});
    const saveSnippet = async (n: Snippet) => {
        await SaveSnippet(n as any);
        setEditingSnippet(null);
    };
    const removeSnippet = async (id: number) => {
        if (!confirm(t('snip.confirmDelSnip'))) return;
        await DeleteSnippet(id);
    };

    return (
        <div className="snippets-layout">
            <aside className="snippets-sidebar">
                <div className="card-header">
                    <span className="card-title">{t('snip.categories')}</span>
                    <button className="ghost-btn" onClick={startNewCategory}>{t('common.new')}</button>
                </div>
                <ul className="cat-list">
                    {categories.map((c) => (
                        <li key={c.id}
                            className={`cat-row ${c.id === selectedCatId ? 'cat-row-active' : ''}`}
                            onClick={() => setSelectedCatId(c.id)}>
                            <span className="cat-name">{c.name}</span>
                            <span className="cat-count">
                                {snap.snippets.filter((n) => n.categoryId === c.id).length}
                            </span>
                        </li>
                    ))}
                    {categories.length === 0 && (
                        <li className="empty-mini">{t('snip.noCategories')}</li>
                    )}
                </ul>
            </aside>

            <section className="snippets-main">
                {currentCategory ? (
                    <>
                        <div className="card-header">
                            <span className="card-title">
                                {currentCategory.name}
                                {currentCategory.matchAppRegex && (
                                    <span className="muted" style={{marginLeft: 8, fontWeight: 400}}>
                                        {t('snip.matchesPrefix')}<code>{currentCategory.matchAppRegex}</code>
                                    </span>
                                )}
                            </span>
                            <div style={{display: 'flex', gap: 6}}>
                                <button className="ghost-btn" onClick={() => startEditCategory(currentCategory)}>{t('snip.editCategory')}</button>
                                <button className="ghost-btn" onClick={() => removeCategory(currentCategory.id)}>{t('common.delete')}</button>
                                <button className="ghost-btn" onClick={startNewSnippet}>{t('snip.newSnippet')}</button>
                            </div>
                        </div>

                        {currentSnippets.length === 0 ? (
                            <div className="empty">{t('snip.noSnippets')}</div>
                        ) : (
                            <ul className="snip-list">
                                {currentSnippets.map((n) => (
                                    <li key={n.id} className="snip-row" onClick={() => startEditSnippet(n)}>
                                        <div className="snip-label">{n.label}</div>
                                        <div className="snip-content">{n.content}</div>
                                    </li>
                                ))}
                            </ul>
                        )}
                    </>
                ) : (
                    <div className="empty">{t('snip.pickCategory')}</div>
                )}
            </section>

            {editingCategory && (
                <CategoryEditor
                    value={editingCategory}
                    onCancel={() => setEditingCategory(null)}
                    onSave={saveCategory}
                />
            )}
            {editingSnippet && (
                <SnippetEditor
                    value={editingSnippet}
                    onCancel={() => setEditingSnippet(null)}
                    onSave={saveSnippet}
                    onDelete={editingSnippet.id > 0 ? () => removeSnippet(editingSnippet.id).then(() => setEditingSnippet(null)) : undefined}
                />
            )}
        </div>
    );
}

const suffixOptions = [
    {v: '', label: 'No suffix'},
    {v: 'enter', label: 'Enter'},
    {v: 'tab', label: 'Tab'},
    {v: 'space', label: 'Space'},
    {v: 'ctrl+enter', label: 'Ctrl + Enter'},
    {v: 'alt+enter', label: 'Alt + Enter'},
    {v: 'shift+enter', label: 'Shift + Enter'},
];

function CategoryEditor(props: { value: Category; onCancel: () => void; onSave: (c: Category) => void }) {
    const [v, setV] = useState<Category>(props.value);
    return (
        <div className="modal-backdrop">
            <div className="modal modal-wide">
                <div className="modal-title">{v.id === 0 ? 'New category' : `Edit ${v.name || 'category'}`}</div>
                <label className="field"><span>Name</span>
                    <input value={v.name} onChange={(e) => setV({...v, name: e.target.value})} autoFocus/>
                </label>
                <label className="field"><span>Prefix (auto-prepended to every send)</span>
                    <input value={v.prefix} onChange={(e) => setV({...v, prefix: e.target.value})}/>
                </label>
                <label className="field"><span>Suffix (auto-appended)</span>
                    <input value={v.suffix} onChange={(e) => setV({...v, suffix: e.target.value})}/>
                </label>
                <label className="field"><span>Default send-suffix key</span>
                    <select value={v.defaultSendSuffix} onChange={(e) => setV({...v, defaultSendSuffix: e.target.value})}>
                        {suffixOptions.map(o => <option key={o.v} value={o.v}>{o.label}</option>)}
                    </select>
                </label>
                <label className="field"><span>Auto-select when focused app matches regex</span>
                    <input value={v.matchAppRegex} onChange={(e) => setV({...v, matchAppRegex: e.target.value})}
                           placeholder="(?i)code|cursor|webstorm"/>
                </label>
                <div className="modal-actions">
                    <button className="ghost-btn" onClick={props.onCancel}>Cancel</button>
                    <button className="ghost-btn primary" onClick={() => props.onSave(v)} disabled={!v.name.trim()}>Save</button>
                </div>
            </div>
        </div>
    );
}

function SnippetEditor(props: {
    value: Snippet;
    onCancel: () => void;
    onSave: (n: Snippet) => void;
    onDelete?: () => void;
}) {
    const [v, setV] = useState<Snippet>(props.value);
    return (
        <div className="modal-backdrop">
            <div className="modal modal-wide">
                <div className="modal-title">{v.id === 0 ? 'New snippet' : `Edit "${v.label || 'snippet'}"`}</div>
                <label className="field"><span>Label (shown on the chip)</span>
                    <input value={v.label} onChange={(e) => setV({...v, label: e.target.value})} autoFocus/>
                </label>
                <label className="field"><span>Content (inserted on tap)</span>
                    <textarea rows={5} value={v.content} onChange={(e) => setV({...v, content: e.target.value})}/>
                </label>
                <div className="modal-actions">
                    {props.onDelete && (
                        <button className="ghost-btn danger" onClick={props.onDelete}>Delete</button>
                    )}
                    <div style={{flex: 1}}/>
                    <button className="ghost-btn" onClick={props.onCancel}>Cancel</button>
                    <button className="ghost-btn primary" onClick={() => props.onSave(v)}
                            disabled={!v.label.trim() || !v.content.trim()}>Save</button>
                </div>
            </div>
        </div>
    );
}
